//
//  TemporaryFileStorageService.swift
//  Notch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()

    // MARK: - Public Interface

    /// Creates a temporary file and tracks it for manual cleanup
    func createTempFile(for type: TempFileType) async -> URL? {
        return await withCheckedContinuation { continuation in
            let result = createTempFile(for: type)
            continuation.resume(returning: result)
        }
    }

    /// An empty folder of its own in the temporary directory, laid out like
    /// `createTempFile` (one UUID folder per output) so
    /// `removeTemporaryFileIfNeeded` cleans up whatever is written into it.
    func createTempDirectory() throws -> URL {
        let dirURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL
    }

    func removeTemporaryFileIfNeeded(at url: URL) {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

        guard url.path.hasPrefix(tempDirectory.path) else {
            Log.shelf.debug("Attempted to remove temporary file outside temp directory: \(url.path)")
            return
        }

        let folderURL = url.deletingLastPathComponent()

        do {
            try FileManager.default.removeItem(at: url)
            Log.shelf.debug("Deleted file: \(url.path)")

            let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: folderURL)
                Log.shelf.debug("Folder was empty, deleted folder: \(folderURL.path)")
            } else {
                Log.shelf.debug("Folder not deleted — it still contains \(contents.count) item(s).")
            }
        } catch {
            Log.shelf.error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Implementation

    private func createTempFile(for type: TempFileType) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let uuid = UUID().uuidString

        switch type {
        case .data(let data, let suggestedName):
            let filename = suggestedName ?? ".dat"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                Log.shelf.error("Error: \(error)")
                return nil
            }

        case .text(let string):
            let filename = "\(uuid).txt"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)

            guard let data = string.data(using: .utf8) else {
                Log.shelf.error("Failed to convert text to data")
                return nil
            }

            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                Log.shelf.error("Error: \(error)")
                return nil
            }

        case .url(let url):
            let filename = "\(url.host ?? uuid).webloc"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)

            let weblocContent = createWeblocContent(for: url)
            guard let data = weblocContent.data(using: String.Encoding.utf8) else {
                Log.shelf.error("Failed to create webloc data")
                return nil
            }

            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                Log.shelf.error("Error: \(error)")
                return nil
            }
        }
    }

    // MARK: - Content Creation Helpers

    private func createWeblocContent(for url: URL) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>URL</key>
            <string>\(url.absoluteString)</string>
        </dict>
        </plist>
        """
    }
}
