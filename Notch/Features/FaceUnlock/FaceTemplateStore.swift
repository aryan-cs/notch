//
//  FaceTemplateStore.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The enrolled face: a handful of L2-normalised embeddings captured across a
//  few frames (so pose/expression variation is covered). A probe is compared to
//  each and scored by the best match. Only embeddings are stored — never an
//  image — in Application Support.
//
//  Two pools: `embeddings` from setup and Improve Recognition, which only the
//  user changes, and `learned`, which Face Unlock adds to by itself (see
//  FaceLearner) and which never pushes the enrolled ones out.
//

import Foundation

struct FaceTemplate: Codable, Equatable {
    var embeddings: [[Float]]
    /// Looks Face Unlock picked up from unlocks; oldest first.
    var learned: [[Float]] = []
    var createdAt: Date
    /// Preprocessing the embeddings were made under; a mismatch invalidates them.
    var version: Int = FaceRecognizer.preprocessingVersion

    init(embeddings: [[Float]], learned: [[Float]] = [], createdAt: Date) {
        self.embeddings = embeddings
        self.learned = learned
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        embeddings = try container.decode([[Float]].self, forKey: .embeddings)
        // Templates saved before learning existed don't have it.
        learned = try container.decodeIfPresent([[Float]].self, forKey: .learned) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        version = try container.decode(Int.self, forKey: .version)
    }

    /// Best cosine similarity of a probe against any stored embedding.
    func bestSimilarity(to probe: [Float]) -> Float {
        (embeddings + learned).map { FaceRecognizer.cosineSimilarity($0, probe) }.max() ?? -1
    }

    /// Best similarity against the enrolled embeddings only, leaving out the
    /// learned ones, so what gets learned is always judged against the face
    /// that was set up and can't drift away from it one sample at a time.
    func enrolledSimilarity(to probe: [Float]) -> Float {
        embeddings.map { FaceRecognizer.cosineSimilarity($0, probe) }.max() ?? -1
    }
}

enum FaceTemplateStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boringNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("face-template.json")
    }

    static func load() -> FaceTemplate? {
        guard let data = try? Data(contentsOf: url),
              let template = try? JSONDecoder().decode(FaceTemplate.self, from: data),
              template.version == FaceRecognizer.preprocessingVersion else { return nil }
        return template
    }

    static func save(_ template: FaceTemplate) {
        guard let data = try? JSONEncoder().encode(template) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static var isEnrolled: Bool {
        (load()?.embeddings.isEmpty == false)
    }
}
