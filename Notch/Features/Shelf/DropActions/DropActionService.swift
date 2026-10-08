//
//  DropActionService.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Runs a drop action on files and returns what it made. Each result goes
//  into a fresh folder of its own in the temporary directory, so inputs are
//  never written to and results never collide; the shelf adds them as
//  temporary items, which it deletes when they're removed.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum DropActionService {
    /// Runs `action` on `inputs` and returns the files it produced, in input
    /// order. The caller holds any security-scoped access the inputs need.
    static func run(_ action: DropAction, on inputs: [URL]) async throws -> [URL] {
        guard !inputs.isEmpty else { return [] }
        switch action {
        case .convert(let format):
            var outputs: [URL] = []
            for input in inputs {
                outputs.append(try await convert(input, to: format))
            }
            return outputs
        case .removeBackground:
            var outputs: [URL] = []
            for input in inputs {
                outputs.append(try await removeBackground(input))
            }
            return outputs
        case .zip:
            return [try await zip(inputs)]
        case .unzip:
            var outputs: [URL] = []
            for input in inputs {
                outputs.append(try await unzip(input))
            }
            return outputs
        }
    }

    // MARK: - Naming

    /// The name `run` gives its result for these inputs, so the shelf can
    /// show it while the work is still going.
    static func outputName(for action: DropAction, inputs: [URL]) -> String {
        let base = inputs.first.map(baseName(of:)) ?? archiveName
        switch action {
        case .convert(let format):
            return "\(base).\(format.fileExtension)"
        case .removeBackground:
            let suffix = String(localized: "background removed", comment: "Appended to an image's file name after its background is removed")
            return "\(base) (\(suffix)).png"
        case .zip:
            return inputs.count == 1 ? "\(base).zip" : "\(archiveName).zip"
        case .unzip:
            return base
        }
    }

    /// Finder's name for an archive of several items.
    private static var archiveName: String {
        String(localized: "Archive", comment: "File name of a zip made from several files")
    }

    /// "Photo.jpg" → "Photo". Folders keep their whole name, dots and all;
    /// bundles ("Notes.app") are named like files.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true {
            return name
        }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// `name` inside `directory`, numbered the way Finder does ("Photo 2.jpg")
    /// when something by that name is already there.
    static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
            candidate = directory.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    // MARK: - Convert

    static func convert(_ input: URL, to format: DropConversionFormat) async throws -> URL {
        let name = outputName(for: .convert(format), inputs: [input])
        guard format.isImage else {
            return try await convertMedia(input, to: format, named: name)
        }
        let data = try ImageProcessingService.encodedImage(from: input, as: format.utType)
        return try await save(data, named: name)
    }

    private static func convertMedia(_ input: URL, to format: DropConversionFormat, named name: String) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let fileType: AVFileType = switch format {
        case .mov: .mov
        case .m4a: .m4a
        default: .mp4
        }
        // Re-wrapping the existing streams is instant and lossless; only
        // re-encode when the codecs don't belong in the new container.
        let presets = format == .m4a
            ? [AVAssetExportPresetAppleM4A]
            : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]

        let directory = try TemporaryFileStorageService.shared.createTempDirectory()
        let output = directory.appendingPathComponent(name)
        var lastError: Error = DropActionError.unsupportedMedia

        for preset in presets {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            do {
                try await export(session, to: output, as: fileType)
                return output
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: output)
            }
        }

        try? FileManager.default.removeItem(at: directory)
        throw lastError
    }

    private static func export(_ session: AVAssetExportSession, to url: URL, as fileType: AVFileType) async throws {
        if #available(macOS 15, *) {
            try await session.export(to: url, as: fileType)
        } else {
            session.outputURL = url
            session.outputFileType = fileType
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? DropActionError.unsupportedMedia
            }
        }
    }

    // MARK: - Remove background

    static func removeBackground(_ input: URL) async throws -> URL {
        let data = try ImageProcessingService.backgroundRemovedPNG(from: input)
        return try await save(data, named: outputName(for: .removeBackground, inputs: [input]))
    }

    // MARK: - Zip

    /// One file or folder zips to "Name.zip" with the item at its root, as
    /// Finder's Compress does; several go side by side in "Archive.zip".
    static func zip(_ inputs: [URL]) async throws -> URL {
        let fileManager = FileManager.default
        let directory = try TemporaryFileStorageService.shared.createTempDirectory()
        do {
            // ditto runs as a child process. Copies inside our own container
            // are files it can certainly read, whatever the sandbox granted
            // for the originals — and on APFS they're clones, so cheap.
            let staging = directory.appendingPathComponent(stagingFolderName, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: staging) }

            var staged: [URL] = []
            for input in inputs {
                let copy = uniqueURL(for: input.lastPathComponent, in: staging)
                try fileManager.copyItem(at: input, to: copy)
                staged.append(copy)
            }

            let archive = directory.appendingPathComponent(outputName(for: .zip, inputs: inputs))
            // A folder needs --keepParent to be its own top-level entry; on a
            // file it would add the staging folder. Without it, a folder's
            // contents become the archive's top level — which is what several
            // items staged side by side want.
            let source: URL
            var arguments = ["-c", "-k", "--sequesterRsrc"]
            if staged.count == 1 {
                source = staged[0]
                if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    arguments.append("--keepParent")
                }
            } else {
                source = staging
            }
            try await runDitto(arguments + [source.path, archive.path])
            return archive
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Unzip

    /// Extracts the way Archive Utility does: a lone top-level item comes
    /// out as itself, several are gathered in a folder named after the
    /// archive.
    static func unzip(_ archive: URL) async throws -> URL {
        let fileManager = FileManager.default
        let directory = try TemporaryFileStorageService.shared.createTempDirectory()
        do {
            let staging = directory.appendingPathComponent(stagingFolderName, isDirectory: true)
            let contents = staging.appendingPathComponent("contents", isDirectory: true)
            try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            let stagedArchive = staging.appendingPathComponent("archive.zip")
            try fileManager.copyItem(at: archive, to: stagedArchive)
            try await runDitto(["-x", "-k", stagedArchive.path, contents.path])

            // ditto folds Finder's __MACOSX resource forks back in; archives
            // from elsewhere can still carry the folder or a stray .DS_Store.
            let entries = try fileManager.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil)
                .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
            guard !entries.isEmpty else { throw DropActionError.emptyArchive }

            if entries.count == 1 {
                let output = directory.appendingPathComponent(entries[0].lastPathComponent)
                try fileManager.moveItem(at: entries[0], to: output)
                return output
            }

            let output = directory.appendingPathComponent(outputName(for: .unzip, inputs: [archive]), isDirectory: true)
            try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
            for entry in entries {
                try fileManager.moveItem(at: entry, to: output.appendingPathComponent(entry.lastPathComponent))
            }
            return output
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Helpers

    /// Hidden, and unique so it can't clash with an archive entry's name.
    private static var stagingFolderName: String { ".staging-\(UUID().uuidString)" }

    private static func save(_ data: Data, named name: String) async throws -> URL {
        guard let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: name)) else {
            throw DropActionError.couldNotSave
        }
        return url
    }

    private static func runDitto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw DropActionError.archiveFailed }
    }
}

enum DropActionError: LocalizedError {
    case noFiles
    case couldNotSave
    case unsupportedMedia
    case archiveFailed
    case emptyArchive

    var errorDescription: String? {
        switch self {
        case .noFiles:
            String(localized: "There were no files to work on")
        case .couldNotSave:
            String(localized: "The result couldn't be saved")
        case .unsupportedMedia:
            String(localized: "This file can't be converted to that format")
        case .archiveFailed:
            String(localized: "The archive couldn't be read or written")
        case .emptyArchive:
            String(localized: "The archive is empty")
        }
    }
}
