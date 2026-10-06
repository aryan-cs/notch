//
//  FaceUnlockLogicTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The pure decision logic behind face unlock: cosine matching and the
//  liveness cues. No camera or model — just the math that gates a match.
//

import XCTest
@testable import boringNotch

final class FaceUnlockLogicTests: XCTestCase {

    // MARK: - Cosine similarity / template matching

    private func unit(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    func testCosineIdenticalIsOne() {
        let a = unit([1, 2, 3, 4])
        XCTAssertEqual(FaceRecognizer.cosineSimilarity(a, a), 1, accuracy: 1e-5)
    }

    func testCosineOrthogonalIsZero() {
        let a = unit([1, 0, 0])
        let b = unit([0, 1, 0])
        XCTAssertEqual(FaceRecognizer.cosineSimilarity(a, b), 0, accuracy: 1e-5)
    }

    func testCosineOppositeIsNegativeOne() {
        let a = unit([1, 1, 0])
        let b = unit([-1, -1, 0])
        XCTAssertEqual(FaceRecognizer.cosineSimilarity(a, b), -1, accuracy: 1e-5)
    }

    func testMismatchedLengthsReturnsNegativeOne() {
        XCTAssertEqual(FaceRecognizer.cosineSimilarity([1, 0], [1, 0, 0]), -1)
    }

    func testTemplateBestSimilarityPicksClosest() {
        let probe = unit([1, 0, 0, 0])
        let template = FaceTemplate(embeddings: [
            unit([0, 1, 0, 0]),   // 0
            unit([0.9, 0.1, 0, 0]), // high
            unit([-1, 0, 0, 0]),  // -1
        ], createdAt: Date())
        XCTAssertGreaterThan(template.bestSimilarity(to: probe), 0.9)
    }

    // MARK: - Liveness

    func testOpennessTallVsFlat() {
        let open = LivenessDecision.openness([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 4)])
        let closed = LivenessDecision.openness([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 0.5)])
        XCTAssertGreaterThan(open, closed)
    }

    func testEyeOpennessIsPerEye() {
        // Two open eyes side by side, in face-box-normalised coordinates.
        let left = [CGPoint(x: 0.20, y: 0.60), CGPoint(x: 0.40, y: 0.60), CGPoint(x: 0.30, y: 0.66)]
        let right = [CGPoint(x: 0.60, y: 0.60), CGPoint(x: 0.80, y: 0.60), CGPoint(x: 0.70, y: 0.66)]
        // Treating both eyes as one region spans the gap between them and reads closed...
        XCTAssertLessThan(LivenessDecision.openness(left + right), 0.15)
        // ...measuring each eye reads open, so a blink can register.
        XCTAssertEqual(LivenessDecision.eyeOpenness(left: left, right: right), 0.3, accuracy: 0.001)
        XCTAssertEqual(LivenessDecision.eyeOpenness(left: left, right: []), 0.3, accuracy: 0.001)
        XCTAssertEqual(LivenessDecision.eyeOpenness(left: [], right: []), 0)
    }

    func testBlinkSeenRequiresOpenThenClosed() {
        XCTAssertTrue(LivenessDecision.blinkSeen([0.3, 0.28, 0.1, 0.3]))   // open -> closed
        XCTAssertFalse(LivenessDecision.blinkSeen([0.1, 0.12, 0.1]))        // never open
        XCTAssertFalse(LivenessDecision.blinkSeen([0.3, 0.29, 0.28]))       // never closed
    }

    func testMotionSeenRange() {
        XCTAssertTrue(LivenessDecision.motionSeen(yaw: [-0.1, 0.1], pitch: [0, 0]))
        XCTAssertFalse(LivenessDecision.motionSeen(yaw: [0.01, 0.0], pitch: [0.0, 0.01]))
    }

    func testIsLiveByLevel() {
        XCTAssertTrue(LivenessDecision.isLive(level: .off, blink: false, motion: false))
        XCTAssertTrue(LivenessDecision.isLive(level: .standard, blink: false, motion: true))
        XCTAssertTrue(LivenessDecision.isLive(level: .standard, blink: true, motion: false))
        XCTAssertFalse(LivenessDecision.isLive(level: .standard, blink: false, motion: false))
        XCTAssertTrue(LivenessDecision.isLive(level: .strict, blink: true, motion: false))
        XCTAssertFalse(LivenessDecision.isLive(level: .strict, blink: false, motion: true))
    }

    // MARK: - Retry shortcut

    func testDoubleTapFiresOnTwoQuickTaps() {
        var d = DoubleTapDetector()
        XCTAssertFalse(d.update(keyDown: true, otherModifiersDown: false, at: 0.00))
        XCTAssertFalse(d.update(keyDown: false, otherModifiersDown: false, at: 0.08))
        XCTAssertFalse(d.update(keyDown: true, otherModifiersDown: false, at: 0.25))
        XCTAssertTrue(d.update(keyDown: false, otherModifiersDown: false, at: 0.33))
        // The tap after a double starts over rather than firing again.
        XCTAssertFalse(d.update(keyDown: true, otherModifiersDown: false, at: 0.45))
        XCTAssertFalse(d.update(keyDown: false, otherModifiersDown: false, at: 0.52))
    }

    func testDoubleTapIgnoresSlowTapsHoldsAndChords() {
        var slow = DoubleTapDetector()      // too long between taps
        _ = slow.update(keyDown: true, otherModifiersDown: false, at: 0.0)
        _ = slow.update(keyDown: false, otherModifiersDown: false, at: 0.1)
        _ = slow.update(keyDown: true, otherModifiersDown: false, at: 0.9)
        XCTAssertFalse(slow.update(keyDown: false, otherModifiersDown: false, at: 1.0))

        var hold = DoubleTapDetector()      // second press held down
        _ = hold.update(keyDown: true, otherModifiersDown: false, at: 0.0)
        _ = hold.update(keyDown: false, otherModifiersDown: false, at: 0.1)
        _ = hold.update(keyDown: true, otherModifiersDown: false, at: 0.2)
        XCTAssertFalse(hold.update(keyDown: false, otherModifiersDown: false, at: 0.9))

        var chord = DoubleTapDetector()     // first tap was Shift+Command
        _ = chord.update(keyDown: true, otherModifiersDown: false, at: 0.0)
        _ = chord.update(keyDown: true, otherModifiersDown: true, at: 0.05)
        _ = chord.update(keyDown: false, otherModifiersDown: false, at: 0.1)
        _ = chord.update(keyDown: true, otherModifiersDown: false, at: 0.2)
        XCTAssertFalse(chord.update(keyDown: false, otherModifiersDown: false, at: 0.3))
    }
}
