//
//  ClipboardHistoryTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  History ordering/eviction rules, what the pasteboard reader keeps or
//  skips, and the manager's capture loop end to end. Everything runs against
//  a uniquely named pasteboard and a temp directory — never the user's
//  clipboard or history.
//

import AppKit
import XCTest
@testable import Notch

final class ClipboardHistoryTests: XCTestCase {

    private func textEntry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            content: .text(text, rtf: nil),
            fingerprint: ClipboardEntry.fingerprint(text: text),
            isPinned: pinned
        )
    }

    private func texts(_ entries: [ClipboardEntry]) -> [String] {
        entries.compactMap(\.textValue)
    }

    // MARK: - ClipboardHistory

    func testRecordInsertsNewestFirst() {
        var history = ClipboardHistory()
        history.record(textEntry("a"), limit: 10)
        history.record(textEntry("b"), limit: 10)
        XCTAssertEqual(texts(history.entries), ["b", "a"])
    }

    func testDuplicateMovesToFrontKeepingIdentityAndPin() {
        var history = ClipboardHistory()
        history.record(textEntry("a", pinned: true), limit: 10)
        let originalID = history.entries[0].id
        history.record(textEntry("b"), limit: 10)

        history.record(textEntry("a"), limit: 10)

        XCTAssertEqual(texts(history.entries), ["a", "b"])
        XCTAssertEqual(history.entries[0].id, originalID)
        XCTAssertTrue(history.entries[0].isPinned)
    }

    func testLimitEvictsOldestUnpinnedOnly() {
        var history = ClipboardHistory()
        history.record(textEntry("pinned", pinned: true), limit: 2)
        history.record(textEntry("a"), limit: 2)
        history.record(textEntry("b"), limit: 2)

        let evicted = history.record(textEntry("c"), limit: 2)

        XCTAssertEqual(texts(evicted), ["a"])
        XCTAssertEqual(texts(history.entries), ["c", "b", "pinned"])
    }

    func testDisplayOrderPutsPinnedFirst() {
        var history = ClipboardHistory()
        history.record(textEntry("old pinned", pinned: true), limit: 10)
        history.record(textEntry("new"), limit: 10)
        XCTAssertEqual(texts(history.displayOrder), ["old pinned", "new"])
    }

    func testUnpinningThenTrimmingEvicts() {
        var history = ClipboardHistory()
        history.record(textEntry("a", pinned: true), limit: 1)
        history.record(textEntry("b"), limit: 1)

        history.togglePin(id: history.entries[1].id)
        let evicted = history.trim(to: 1)

        XCTAssertEqual(texts(evicted), ["a"])
        XCTAssertEqual(texts(history.entries), ["b"])
    }

    func testClearKeepingPinned() {
        var history = ClipboardHistory()
        history.record(textEntry("pinned", pinned: true), limit: 10)
        history.record(textEntry("a"), limit: 10)

        let removed = history.clear(keepingPinned: true)

        XCTAssertEqual(texts(removed), ["a"])
        XCTAssertEqual(texts(history.entries), ["pinned"])
    }

    func testPromoteMovesEntryToFront() {
        var history = ClipboardHistory()
        history.record(textEntry("a"), limit: 10)
        history.record(textEntry("b"), limit: 10)
        history.promote(id: history.entries[1].id)
        XCTAssertEqual(texts(history.entries), ["a", "b"])
    }

    // MARK: - ClipboardEntry

    func testLinkDetection() {
        XCTAssertEqual(textEntry("https://github.com/x").linkURL?.host(), "github.com")
        XCTAssertEqual(textEntry("  http://example.com  \n").linkURL?.host(), "example.com")
        XCTAssertNil(textEntry("see https://github.com").linkURL)
        XCTAssertNil(textEntry("ftp://example.com").linkURL)
        XCTAssertNil(textEntry("github.com").linkURL)
    }

    // MARK: - ClipboardReader

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("ClipboardHistoryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func write(_ values: [(NSPasteboard.PasteboardType, Data)]) {
        let item = NSPasteboardItem()
        for (type, data) in values {
            item.setData(data, forType: type)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testReadsPlainTextWithRTF() {
        let rtf = Data("{\\rtf1 hi}".utf8)
        write([(.string, Data("hello".utf8)), (.rtf, rtf)])
        XCTAssertEqual(ClipboardReader.read(pasteboard), .text("hello", rtf: rtf))
    }

    func testSkipsConcealedContent() {
        write([
            (.string, Data("hunter2".utf8)),
            (.init("org.nspasteboard.ConcealedType"), Data()),
        ])
        XCTAssertNil(ClipboardReader.read(pasteboard))
    }

    func testSkipsTransientContent() {
        write([
            (.string, Data("temp".utf8)),
            (.init("org.nspasteboard.TransientType"), Data()),
        ])
        XCTAssertNil(ClipboardReader.read(pasteboard))
    }

    func testSkipsWhitespaceOnlyText() {
        write([(.string, Data("  \n\t ".utf8))])
        XCTAssertNil(ClipboardReader.read(pasteboard))
    }

    func testFileURLsWinOverTheirNames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Finder's shape: the file URL plus its name as plain text.
        write([
            (.fileURL, Data(url.absoluteString.utf8)),
            (.string, Data(url.lastPathComponent.utf8)),
        ])

        XCTAssertEqual(ClipboardReader.read(pasteboard), .files([url]))
    }

    func testImageListedFirstIsReadAsImage() throws {
        let png = try pngData(width: 4, height: 4)
        write([(.png, png), (.string, Data("https://example.com/a.png".utf8))])
        XCTAssertEqual(ClipboardReader.read(pasteboard), .image(png))
    }

    func testTextListedFirstIsReadAsText() throws {
        let png = try pngData(width: 4, height: 4)
        write([(.string, Data("A table cell".utf8)), (.png, png)])
        XCTAssertEqual(ClipboardReader.read(pasteboard), .text("A table cell", rtf: nil))
    }

    func testThumbnailShortSideCoversCard() throws {
        // Wide screenshot: cropped to a square card, so the 600px side is
        // the one that must stay at least 320px.
        let png = try pngData(width: 1200, height: 600)
        let processed = try XCTUnwrap(ProcessedClipboardImage.process(png))
        XCTAssertEqual(processed.pixelWidth, 1200)
        XCTAssertEqual(processed.pixelHeight, 600)

        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: processed.thumbnailPNG))
        XCTAssertEqual(thumbnail.pixelsHigh, ProcessedClipboardImage.thumbnailMinShortSide)
        XCTAssertEqual(thumbnail.pixelsWide, 640)
    }

    func testThumbnailLongSideIsCapped() throws {
        let png = try pngData(width: 4000, height: 200)
        let processed = try XCTUnwrap(ProcessedClipboardImage.process(png))
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: processed.thumbnailPNG))
        XCTAssertEqual(thumbnail.pixelsWide, ProcessedClipboardImage.thumbnailMaxLongSide)
    }

    // MARK: - ClipboardHistoryManager

    @MainActor
    private func makeManager(
        frontmost: String? = "com.apple.TextEdit"
    ) -> (ClipboardHistoryManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manager = ClipboardHistoryManager(
            pasteboard: pasteboard,
            storage: ClipboardStorage(directory: directory),
            frontmostBundleID: { frontmost }
        )
        return (manager, directory)
    }

    private func copy(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    @MainActor
    func testManagerRecordsNewCopies() {
        let (manager, _) = makeManager()
        copy("first")
        manager.checkForChanges()
        copy("second")
        manager.checkForChanges()

        XCTAssertEqual(texts(manager.entries), ["second", "first"])
        XCTAssertEqual(manager.entries.first?.sourceBundleID, "com.apple.TextEdit")
    }

    @MainActor
    func testManagerIgnoresUnchangedPasteboard() {
        let (manager, _) = makeManager()
        copy("once")
        manager.checkForChanges()
        manager.checkForChanges()
        XCTAssertEqual(manager.entries.count, 1)
    }

    @MainActor
    func testManagerSkipsPasswordManagers() {
        let (manager, _) = makeManager(frontmost: "com.1password.1password")
        copy("secret")
        manager.checkForChanges()
        XCTAssertTrue(manager.isEmpty)
    }

    @MainActor
    func testSelectingDoesNotRecordItsOwnWrite() throws {
        let (manager, _) = makeManager()
        copy("a")
        manager.checkForChanges()
        copy("b")
        manager.checkForChanges()

        let a = try XCTUnwrap(manager.entries.first { $0.textValue == "a" })
        manager.select(a)
        manager.checkForChanges()

        XCTAssertEqual(pasteboard.string(forType: .string), "a")
        XCTAssertEqual(texts(manager.entries), ["a", "b"])
        XCTAssertEqual(manager.entries.first?.id, a.id)
    }

    @MainActor
    func testImageCaptureStoresFilesAndCleansUpOnRemove() async throws {
        let (manager, directory) = makeManager()
        let png = try pngData(width: 640, height: 480)

        await manager.ingest(.image(png), source: "com.apple.Preview")?.value
        // The same picture again is promoted, not duplicated.
        await manager.ingest(.image(png), source: "com.apple.Preview")?.value

        XCTAssertEqual(manager.entries.count, 1)
        let entry = try XCTUnwrap(manager.entries.first)
        guard case .image(let fileName, let thumbnailFileName, 640, 480) = entry.content else {
            return XCTFail("Expected a 640×480 image, got \(entry.content)")
        }
        let images = directory.appendingPathComponent("Images")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: images.path)),
            [fileName, thumbnailFileName]
        )
        XCTAssertNotNil(manager.thumbnail(for: entry))

        manager.remove(entry)

        XCTAssertTrue(manager.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: images.path), [])
    }

    @MainActor
    func testHistorySurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ClipboardHistoryManager(
            pasteboard: pasteboard, storage: ClipboardStorage(directory: directory), frontmostBundleID: { nil }
        )
        copy("remember me")
        first.checkForChanges()
        first.flushSync()

        let second = ClipboardHistoryManager(
            pasteboard: pasteboard, storage: ClipboardStorage(directory: directory), frontmostBundleID: { nil }
        )
        XCTAssertEqual(texts(second.entries), ["remember me"])
    }
}
