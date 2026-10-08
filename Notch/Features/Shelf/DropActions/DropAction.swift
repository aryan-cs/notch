//
//  DropAction.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the shelf's drop actions do and which of them fit what's being
//  dragged. Worked out from file types alone, so it can run mid-drag —
//  before the sandbox lets us read the files themselves.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One of the targets shown beside the shelf while files are dragged over
/// the notch. `DropAction` adds the format a conversion targets.
enum DropActionKind: CaseIterable, Hashable, Sendable {
    case convert
    case removeBackground
    case unzip
    case zip

    var title: String {
        switch self {
        case .convert: String(localized: "Convert", comment: "Shelf drop action")
        case .removeBackground: String(localized: "Remove BG", comment: "Shelf drop action: remove an image's background")
        case .unzip: String(localized: "Unzip", comment: "Shelf drop action")
        case .zip: String(localized: "Zip", comment: "Shelf drop action")
        }
    }

    var symbolName: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .removeBackground: "person.and.background.dotted"
        case .unzip: "arrow.up.bin.fill"
        case .zip: "archivebox.fill"
        }
    }
}

enum DropAction: Hashable, Sendable {
    case convert(DropConversionFormat)
    case removeBackground
    case unzip
    case zip

    var kind: DropActionKind {
        switch self {
        case .convert: .convert
        case .removeBackground: .removeBackground
        case .unzip: .unzip
        case .zip: .zip
        }
    }

    /// Zip makes one archive from everything dropped; the others produce
    /// one result per file.
    var combinesInputs: Bool { self == .zip }
}

/// Formats Convert can produce: still images through ImageIO, audio and
/// video through AVFoundation.
enum DropConversionFormat: String, CaseIterable, Hashable, Sendable {
    case jpeg, png, heic, tiff
    case mp4, mov, m4a

    static let imageFormats: [DropConversionFormat] = [.jpeg, .png, .heic, .tiff]
    static let videoFormats: [DropConversionFormat] = [.mp4, .mov, .m4a]

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4a: UTType("com.apple.m4a-audio") ?? .mpeg4Audio
        }
    }

    /// Spelled the way Finder names these files, not UTType's preferred
    /// extension ("jpeg", and "mp4" for audio).
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .mp4: "mp4"
        case .mov: "mov"
        case .m4a: "m4a"
        }
    }

    var title: String { rawValue.uppercased() }

    var isImage: Bool { Self.imageFormats.contains(self) }

    var symbolName: String {
        switch self {
        case .jpeg, .png, .heic, .tiff: "photo.fill"
        case .mp4, .mov: "film.fill"
        case .m4a: "waveform"
        }
    }

    /// Whether `type` is already this format, so converting would be a no-op.
    func matches(_ type: UTType) -> Bool {
        type == utType || (self == .jpeg && type.conforms(to: .jpeg))
    }
}

/// The actions (and conversion formats) that apply to a set of dragged or
/// selected files.
struct DropActionAvailability: Equatable, Sendable {
    let actions: [DropActionKind]
    /// Convert's targets, most useful first; the first is what a quick drop
    /// on Convert produces.
    let formats: [DropConversionFormat]

    static let none = DropActionAvailability(actions: [], formats: [])

    var isEmpty: Bool { actions.isEmpty }

    /// - Parameter contentTypes: One entry per dragged item; `nil` for
    ///   anything that isn't a file (text, a web link).
    init(contentTypes: [UTType?]) {
        let types = contentTypes.compactMap { $0 }
        // Text and links have no file to act on, and a mixed drag can't be
        // dropped on a file-only target as a whole.
        guard !types.isEmpty, types.count == contentTypes.count else {
            self = .none
            return
        }

        var actions: [DropActionKind] = []
        var formats: [DropConversionFormat] = []

        if types.allSatisfy(Self.isConvertibleImage) {
            formats = DropConversionFormat.imageFormats
            actions += [.convert, .removeBackground]
        } else if types.allSatisfy({ $0.conforms(to: .audiovisualContent) }) {
            // Video can be re-wrapped or reduced to its soundtrack; audio
            // alone can only become M4A.
            let hasVideo = types.allSatisfy { $0.conforms(to: .movie) }
            formats = hasVideo ? DropConversionFormat.videoFormats : [.m4a]
            actions.append(.convert)
        } else if types.allSatisfy({ $0.conforms(to: .zip) }) {
            actions.append(.unzip)
        }

        // Converting to the format everything already is would do nothing.
        formats.removeAll { format in types.allSatisfy(format.matches) }
        if formats.isEmpty {
            actions.removeAll { $0 == .convert }
        }

        actions.append(.zip)
        self.init(actions: actions, formats: formats)
    }

    init(actions: [DropActionKind], formats: [DropConversionFormat]) {
        self.actions = actions
        self.formats = formats
    }

    init(fileURLs: [URL]) {
        self.init(contentTypes: fileURLs.map(Self.contentType(ofFileAt:)))
    }

    /// Images ImageIO can decode — SVG conforms to `public.image` but isn't
    /// one of them.
    static func isConvertibleImage(_ type: UTType) -> Bool {
        type.conforms(to: .image) && readableImageTypes.contains(type.identifier)
    }

    private static let readableImageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    static func contentType(ofFileAt url: URL) -> UTType {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return contentType(forPath: url.path)
    }

    /// The type a path's extension implies. Folders and extensionless files
    /// count as plain items: zippable, nothing else.
    static func contentType(forPath path: String) -> UTType {
        let pathExtension = (path as NSString).pathExtension
        guard !pathExtension.isEmpty, !path.hasSuffix("/") else { return .item }
        return UTType(filenameExtension: pathExtension) ?? .item
    }
}

// MARK: - Reading the drag

extension DropActionAvailability {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")

    /// What applies to whatever is being dragged right now.
    static func forCurrentDrag() -> DropActionAvailability {
        forDrag(on: NSPasteboard(name: .drag))
    }

    /// Only names and type identifiers are read: the sandbox doesn't open
    /// the files until they're dropped.
    static func forDrag(on pasteboard: NSPasteboard) -> DropActionAvailability {
        // Finder writes file *reference* URLs (file:///.file/id=…), which
        // carry no extension and can't be resolved from the sandbox; its
        // legacy filenames list has the real paths.
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return DropActionAvailability(contentTypes: paths.map(contentType(forPath:)))
        }
        let items = pasteboard.pasteboardItems ?? []
        return DropActionAvailability(contentTypes: items.map(contentType(of:)))
    }

    private static func contentType(of item: NSPasteboardItem) -> UTType? {
        if let string = item.string(forType: .fileURL), let url = URL(string: string) {
            let resolved = (url as NSURL).filePathURL ?? url
            // An unresolvable reference URL is still a file, just of unknown type.
            return resolved.path.hasPrefix("/.file/") ? .item : contentType(forPath: resolved.path)
        }
        // Promised files (Photos, Mail, browsers) announce their type up front.
        if let identifier = item.string(forType: promisedContentType), let type = UTType(identifier) {
            return type
        }
        // Raw image or movie data, like an image dragged out of a web page.
        return item.types.lazy
            .compactMap { UTType($0.rawValue) }
            .first { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }
    }
}
