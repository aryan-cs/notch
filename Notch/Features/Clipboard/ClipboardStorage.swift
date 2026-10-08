//
//  ClipboardStorage.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  On-disk layout for clipboard history:
//
//    Application Support/boringNotch/Clipboard/
//      history.json          entries, most recent first
//      Images/<id>.png       full image, written back on paste
//      Images/<id>-thumb.png thumbnail drawn in the notch (short side 320px)
//
//  Writes are atomic, like ShelfPersistenceService. Image files are owned by
//  the entry that references them: whoever drops an entry calls
//  `removeFiles(for:)`.
//

import Foundation

final class ClipboardStorage: Sendable {
    let imagesDirectory: URL
    private let historyURL: URL

    init(directory: URL? = nil) {
        let fm = FileManager.default
        let root = directory ?? {
            let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return (support ?? fm.temporaryDirectory)
                .appendingPathComponent("boringNotch", isDirectory: true)
                .appendingPathComponent("Clipboard", isDirectory: true)
        }()
        imagesDirectory = root.appendingPathComponent("Images", isDirectory: true)
        historyURL = root.appendingPathComponent("history.json")
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: History file

    func load() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        do {
            return try Self.makeDecoder().decode([ClipboardEntry].self, from: data)
        } catch {
            // A partial history isn't worth recovering item by item like the
            // shelf does — these are copies, not the user's files.
            Log.clipboard.error("Discarding unreadable clipboard history: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ entries: [ClipboardEntry]) {
        Self.write(entries, to: historyURL)
    }

    func saveAsync(_ entries: [ClipboardEntry]) async {
        let url = historyURL
        await Task.detached(priority: .utility) {
            Self.write(entries, to: url)
        }.value
    }

    func deleteHistoryFile() {
        try? FileManager.default.removeItem(at: historyURL)
    }

    private static func write(_ entries: [ClipboardEntry], to url: URL) {
        do {
            let data = try makeEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.clipboard.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Image files

    func imageURL(_ fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Writes both files for a new image entry and returns its content.
    func writeImage(_ image: ProcessedClipboardImage, id: UUID) throws -> ClipboardContent {
        let fileName = "\(id.uuidString).png"
        let thumbnailFileName = "\(id.uuidString)-thumb.png"
        try image.png.write(to: imageURL(fileName), options: .atomic)
        do {
            try image.thumbnailPNG.write(to: imageURL(thumbnailFileName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL(fileName))
            throw error
        }
        return .image(
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight
        )
    }

    /// False for an image entry whose files have gone missing.
    func hasFiles(for entry: ClipboardEntry) -> Bool {
        guard case .image(let fileName, let thumbnailFileName, _, _) = entry.content else { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: imageURL(fileName).path)
            && fm.fileExists(atPath: imageURL(thumbnailFileName).path)
    }

    func removeFiles(for entries: [ClipboardEntry]) {
        for name in entries.flatMap(Self.fileNames(of:)) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
    }

    /// Deletes images no entry points at — left behind if the app quit
    /// between writing an image and saving the history that references it.
    func removeUnreferencedImages(keeping entries: [ClipboardEntry]) {
        let referenced = Set(entries.flatMap(Self.fileNames(of:)))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for name in files where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
    }

    private static func fileNames(of entry: ClipboardEntry) -> [String] {
        guard case .image(let fileName, let thumbnailFileName, _, _) = entry.content else { return [] }
        return [fileName, thumbnailFileName]
    }
}
