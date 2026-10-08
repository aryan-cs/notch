//
//  ClipboardEntry.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Clipboard history model. `ClipboardHistory` is a plain value type so the
//  ordering, de-duplication and eviction rules can be unit tested without a
//  pasteboard, a timer or the file system.
//

import CryptoKit
import Foundation

enum ClipboardContent: Codable, Hashable {
    /// Plain text, plus the RTF the source app offered (if any) so pasting
    /// an entry back keeps its formatting.
    case text(String, rtf: Data?)
    /// A PNG stored in the clipboard image directory; `fileName` is relative
    /// to it so the history survives the container path changing.
    case image(fileName: String, thumbnailFileName: String, pixelWidth: Int, pixelHeight: Int)
    case files([URL])
}

struct ClipboardEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var content: ClipboardContent
    /// Identity used for de-duplication: copying the same thing twice moves
    /// the existing entry to the front instead of adding a second one.
    let fingerprint: String
    /// When the content was last copied, not when it was first seen.
    var date: Date
    var sourceBundleID: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        fingerprint: String,
        date: Date = Date(),
        sourceBundleID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.content = content
        self.fingerprint = fingerprint
        self.date = date
        self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned
    }

    var textValue: String? {
        if case .text(let string, _) = content { return string }
        return nil
    }

    /// A single http(s) link copied on its own, shown with a link affordance.
    var linkURL: URL? {
        guard let text = textValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// Text that is just a hex color — picked with the eyedropper or copied
    /// from code — shown as a swatch.
    var colorValue: ClipboardColor? {
        // Every render asks; don't trim a long copy just to say no.
        guard let text = textValue, text.utf8.count <= 64 else { return nil }
        return ClipboardColor.detect(in: text)
    }

    static func fingerprint(text: String) -> String {
        "text:" + sha256(Data(text.utf8))
    }

    static func fingerprint(files: [URL]) -> String {
        "files:" + files.map(\.standardizedFileURL.path).joined(separator: "\n")
    }

    static func fingerprint(imageData: Data) -> String {
        "image:" + sha256(imageData)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardHistory: Equatable {
    /// Most recently copied first. Pinned entries live in the same list;
    /// `displayOrder` floats them to the front.
    private(set) var entries: [ClipboardEntry]

    init(entries: [ClipboardEntry] = []) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Pinned entries first, each group most-recent first.
    var displayOrder: [ClipboardEntry] {
        entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
    }

    /// Inserts `entry` at the front. A duplicate (same fingerprint) is
    /// replaced in place of being added again, keeping its id and pin so
    /// SwiftUI identity and the user's pin survive re-copying.
    ///
    /// Returns entries dropped to stay within `limit` — the caller owns any
    /// files they reference. Pinned entries never count toward the limit and
    /// are never evicted.
    @discardableResult
    mutating func record(_ entry: ClipboardEntry, limit: Int) -> [ClipboardEntry] {
        var inserted = entry
        var replaced: [ClipboardEntry] = []
        if let index = entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            let existing = entries.remove(at: index)
            inserted = ClipboardEntry(
                id: existing.id,
                content: entry.content,
                fingerprint: entry.fingerprint,
                date: entry.date,
                sourceBundleID: entry.sourceBundleID ?? existing.sourceBundleID,
                isPinned: existing.isPinned
            )
            // The new capture carries its own image files; the old ones are
            // orphaned unless both point at the same file.
            if existing.content != entry.content {
                replaced.append(existing)
            }
        }
        entries.insert(inserted, at: 0)
        return replaced + trim(to: limit)
    }

    /// Moves an existing entry to the front, as if it had just been copied.
    mutating func promote(id: UUID, date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.date = date
        entries.insert(entry, at: 0)
    }

    @discardableResult
    mutating func remove(id: UUID) -> ClipboardEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    mutating func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
    }

    /// Drops unpinned entries beyond `limit`, oldest first.
    @discardableResult
    mutating func trim(to limit: Int) -> [ClipboardEntry] {
        var unpinnedSeen = 0
        var kept: [ClipboardEntry] = []
        var evicted: [ClipboardEntry] = []
        for entry in entries {
            if entry.isPinned {
                kept.append(entry)
            } else if unpinnedSeen < max(limit, 0) {
                unpinnedSeen += 1
                kept.append(entry)
            } else {
                evicted.append(entry)
            }
        }
        entries = kept
        return evicted
    }

    /// Removes every entry, or every unpinned entry. Returns what was removed.
    @discardableResult
    mutating func clear(keepingPinned: Bool) -> [ClipboardEntry] {
        let removed = keepingPinned ? entries.filter { !$0.isPinned } : entries
        entries = keepingPinned ? entries.filter(\.isPinned) : []
        return removed
    }
}
