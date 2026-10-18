//
//  FaceLearner.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock getting better on its own, the way Face ID does. Nothing is
//  retrained: it adds a look at your face to the template's `learned` pool
//  in two cases.
//
//  - A slow match: a scan that only recognized you after many frames saves
//    the frame that finally matched, so that lighting matches sooner.
//  - A miss you then unlocked with your password (or Touch ID): the best
//    near-miss from just before the unlock is saved, since whoever unlocked
//    was in front of the camera.
//
//  The second is the risky one: someone else could have been in front of the
//  camera while you typed. So only near-misses count, scored against the
//  enrolled face alone: frames a little short of the matching threshold,
//  which other people's faces score well below. It takes more than one of
//  them, a learned look that adds nothing new is skipped, and the pool is
//  small, with the oldest dropping out first.
//

import Foundation

struct FaceLearner {
    /// Learned looks kept at most; the oldest goes first.
    static let maxLearned = 10
    /// How far below the matching threshold a missed frame can score (against
    /// the enrolled face) and still be learned...
    static let nearMissMargin: Float = 0.12
    /// ...but never below this, whatever the threshold.
    static let minimumSimilarity: Float = 0.25
    /// A frame scoring this far above the threshold is already well covered.
    static let wellCoveredMargin: Float = 0.15
    /// A look this similar to one already stored adds nothing.
    static let redundantSimilarity: Float = 0.85
    /// Near-misses count only if the unlock comes within this long.
    static let unlockWindow: TimeInterval = 20
    /// Near-misses needed before a miss teaches anything, so one odd frame can't.
    static let minimumNearMisses = 2
    /// A match after at least this many frames was slow (it usually takes 3–6).
    static let slowMatchFrames = 15

    struct Look {
        let embedding: [Float]
        /// Best similarity against the whole template, as matching sees it.
        let similarity: Float
        /// Best similarity against the enrolled embeddings only.
        let enrolledSimilarity: Float
        let time: TimeInterval
    }

    /// Frames worth learning from, since the last reset.
    private(set) var looks: [Look] = []

    static func floor(threshold: Float) -> Float {
        max(threshold - nearMissMargin, minimumSimilarity)
    }

    mutating func reset() {
        looks.removeAll()
    }

    /// Feed every scanned frame. Keeps clear, live faces that the enrolled
    /// face nearly or barely matches.
    mutating func observe(_ frame: FaceUnlockEngine.Frame, template: FaceTemplate, threshold: Float, at time: TimeInterval) {
        guard frame.isLive, frame.isClear, let embedding = frame.embedding,
              frame.similarity < threshold + Self.wellCoveredMargin else { return }
        let enrolled = template.enrolledSimilarity(to: embedding)
        guard enrolled >= Self.floor(threshold: threshold) else { return }
        looks.append(Look(embedding: embedding, similarity: frame.similarity, enrolledSimilarity: enrolled, time: time))
        // Only the recent ones are ever used.
        if looks.count > 60 { looks.removeFirst(looks.count - 60) }
    }

    /// The scan matched after `frames` frames at `time`: the frame that
    /// matched, if it was slow to get there.
    func lookForSlowMatch(frames: Int, at time: TimeInterval, threshold: Float) -> Look? {
        guard frames >= Self.slowMatchFrames else { return nil }
        return looks.last { time - $0.time < 1 && $0.similarity >= threshold }
    }

    /// The screen was unlocked some other way at `time` after a miss: the
    /// most convincing recent near-miss, if there were enough of them.
    func lookForPasswordUnlock(at time: TimeInterval, threshold: Float) -> Look? {
        let recent = looks.filter { time - $0.time <= Self.unlockWindow && $0.similarity < threshold }
        guard recent.count >= Self.minimumNearMisses else { return nil }
        return recent.max { $0.enrolledSimilarity < $1.enrolledSimilarity }
    }
}

extension FaceTemplate {
    /// This template with `embedding` learned, or nil if it adds nothing new.
    func learning(_ embedding: [Float]) -> FaceTemplate? {
        guard bestSimilarity(to: embedding) < FaceLearner.redundantSimilarity else { return nil }
        var template = self
        template.learned = Array((learned + [embedding]).suffix(FaceLearner.maxLearned))
        return template
    }
}
