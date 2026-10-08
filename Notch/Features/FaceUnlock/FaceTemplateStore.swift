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

import Foundation

struct FaceTemplate: Codable, Equatable {
    var embeddings: [[Float]]
    var createdAt: Date
    /// Preprocessing the embeddings were made under; a mismatch invalidates them.
    var version: Int = FaceRecognizer.preprocessingVersion

    /// Best cosine similarity of a probe against any enrolled embedding.
    func bestSimilarity(to probe: [Float]) -> Float {
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
