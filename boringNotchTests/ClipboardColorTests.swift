//
//  ClipboardColorTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Color entries: parsing and detecting hex text, every copy format, the
//  sRGB conversion of sampled colors, and the manager copying a picked
//  color and the other formats. Runs against a private pasteboard and a
//  temp directory, like ClipboardHistoryTests.
//

import AppKit
import XCTest
@testable import boringNotch

final class ClipboardColorTests: XCTestCase {

    private let blue = ClipboardColor(red: 58, green: 123, blue: 255)

    // MARK: - Parsing

    func testParsesEveryHexForm() {
        XCTAssertEqual(ClipboardColor(hex: "#3A7BFF"), blue)
        XCTAssertEqual(ClipboardColor(hex: "#3a7bff"), blue)
        XCTAssertEqual(ClipboardColor(hex: "#F80"), ClipboardColor(red: 255, green: 136, blue: 0))
        XCTAssertEqual(ClipboardColor(hex: "#F808"), ClipboardColor(red: 255, green: 136, blue: 0, alpha: 136))
        XCTAssertEqual(ClipboardColor(hex: "#3A7BFF80"), ClipboardColor(red: 58, green: 123, blue: 255, alpha: 128))
    }

    func testRejectsMalformedHex() {
        for text in ["3A7BFF", "#3A7BF", "#3A7BFF8", "#GGGGGG", "#", "#3A7BFF0000", "#ＦＦＦ", "# FFF"] {
            XCTAssertNil(ClipboardColor(hex: text), text)
        }
    }

    func testDetectsColorTextOnly() {
        XCTAssertEqual(ClipboardColor.detect(in: "  #3A7BFF\n"), blue)
        XCTAssertEqual(ClipboardColor.detect(in: "#fff"), ClipboardColor(red: 255, green: 255, blue: 255))
        XCTAssertEqual(ClipboardColor.detect(in: "#333"), ClipboardColor(red: 51, green: 51, blue: 51))
        XCTAssertEqual(ClipboardColor.detect(in: "#123456"), ClipboardColor(red: 18, green: 52, blue: 86))

        XCTAssertNil(ClipboardColor.detect(in: "#3A7BFF is blue"))
        XCTAssertNil(ClipboardColor.detect(in: "color: #3A7BFF;"))
        // Issue and PR numbers, not colors.
        XCTAssertNil(ClipboardColor.detect(in: "#123"))
        XCTAssertNil(ClipboardColor.detect(in: "#1234"))
    }

    func testTextEntriesExposeTheirColor() {
        let entry = ClipboardEntry(content: .text("#3A7BFF", rtf: nil), fingerprint: ClipboardEntry.fingerprint(text: "#3A7BFF"))
        XCTAssertEqual(entry.colorValue, blue)

        let long = String(repeating: "#3A7BFF ", count: 20)
        XCTAssertNil(ClipboardEntry(content: .text(long, rtf: nil), fingerprint: "x").colorValue)
        XCTAssertNil(ClipboardEntry(content: .files([]), fingerprint: "files:").colorValue)
    }

    // MARK: - Formats

    func testFormatsOpaqueColor() {
        XCTAssertEqual(blue.hex, "#3A7BFF")
        XCTAssertEqual(blue.rgb, "rgb(58, 123, 255)")
        XCTAssertEqual(blue.rgba, "rgba(58, 123, 255, 1)")
        XCTAssertEqual(blue.hsl, "hsl(220, 100%, 61%)")
        XCTAssertEqual(blue.swiftUI, "Color(red: 0.227, green: 0.482, blue: 1)")
        XCTAssertEqual(blue.nsColor, "NSColor(srgbRed: 0.227, green: 0.482, blue: 1, alpha: 1)")
    }

    func testFormatsTranslucentColor() {
        let color = ClipboardColor(red: 255, green: 0, blue: 0, alpha: 128)
        XCTAssertEqual(color.hex, "#FF000080")
        XCTAssertEqual(color.rgb, "rgb(255, 0, 0)")
        XCTAssertEqual(color.rgba, "rgba(255, 0, 0, 0.5)")
        XCTAssertEqual(color.hsl, "hsla(0, 100%, 50%, 0.5)")
        XCTAssertEqual(color.swiftUI, "Color(red: 1, green: 0, blue: 0, opacity: 0.502)")
        XCTAssertEqual(color.nsColor, "NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.502)")
    }

    func testHexPadsSmallComponents() {
        XCTAssertEqual(ClipboardColor(red: 0, green: 10, blue: 15).hex, "#000A0F")
    }

    func testHSLCoversEveryHueSector() {
        XCTAssertEqual(ClipboardColor(red: 0, green: 0, blue: 0).hsl, "hsl(0, 0%, 0%)")
        XCTAssertEqual(ClipboardColor(red: 255, green: 255, blue: 255).hsl, "hsl(0, 0%, 100%)")
        XCTAssertEqual(ClipboardColor(red: 128, green: 128, blue: 128).hsl, "hsl(0, 0%, 50%)")
        XCTAssertEqual(ClipboardColor(red: 0, green: 255, blue: 0).hsl, "hsl(120, 100%, 50%)")
        XCTAssertEqual(ClipboardColor(red: 255, green: 0, blue: 255).hsl, "hsl(300, 100%, 50%)")
        // Red is the largest component but blue beats green: negative hue
        // wraps around.
        XCTAssertEqual(ClipboardColor(red: 255, green: 0, blue: 64).hsl, "hsl(345, 100%, 50%)")
        XCTAssertEqual(ClipboardColor(red: 204, green: 102, blue: 51).hsl, "hsl(20, 60%, 50%)")
    }

    func testCodeSnippetsRoundTripEveryByte() {
        for byte in UInt8.min...UInt8.max {
            let color = ClipboardColor(red: byte, green: byte, blue: byte)
            let value = color.nsColor.split(separator: " ")[1].dropLast()  // "0.227,"
            XCTAssertEqual(UInt8((Double(value)! * 255).rounded()), byte)
        }
    }

    // MARK: - Sampled colors

    func testSampledColorsAreConvertedToSRGB() {
        XCTAssertEqual(ClipboardColor(NSColor(srgbRed: 58 / 255, green: 123 / 255, blue: 1, alpha: 1)), blue)
        // P3 and sRGB share white point and curve, so grays come out equal…
        XCTAssertEqual(
            ClipboardColor(NSColor(displayP3Red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
            ClipboardColor(red: 128, green: 128, blue: 128)
        )
        // …while P3's pure red lies outside sRGB and is clamped to its edge.
        XCTAssertEqual(
            ClipboardColor(NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)),
            ClipboardColor(red: 255, green: 0, blue: 0)
        )
        // An in-gamut P3 color is converted, not reinterpreted.
        let p3 = ClipboardColor(NSColor(displayP3Red: 0.5, green: 0.3, blue: 0.2, alpha: 1))
        XCTAssertNotEqual(p3, ClipboardColor(red: 128, green: 77, blue: 51))
    }

    func testSampledAlphaIsKept() {
        XCTAssertEqual(ClipboardColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))?.alpha, 128)
    }

    // MARK: - Manager

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("ClipboardColorTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    @MainActor
    private func makeManager(directory: URL) -> ClipboardHistoryManager {
        ClipboardHistoryManager(
            pasteboard: pasteboard,
            storage: ClipboardStorage(directory: directory),
            frontmostBundleID: { "com.apple.TextEdit" }
        )
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardColorTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testPickedColorIsCopiedAsHexAndRecordedOnce() throws {
        let manager = makeManager(directory: makeDirectory())

        let entry = try XCTUnwrap(manager.copy(blue))
        manager.checkForChanges()

        XCTAssertEqual(pasteboard.string(forType: .string), "#3A7BFF")
        XCTAssertEqual(manager.entries.map(\.id), [entry.id])
        XCTAssertEqual(entry.colorValue, blue)
        XCTAssertEqual(manager.recentlySelectedID, entry.id)
    }

    @MainActor
    func testPickingAColorAgainMovesItToTheFront() throws {
        let manager = makeManager(directory: makeDirectory())
        let first = try XCTUnwrap(manager.copy(blue))
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        manager.checkForChanges()

        let again = try XCTUnwrap(manager.copy(blue))

        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(manager.entries.map(\.textValue), ["#3A7BFF", "something else"])
    }

    @MainActor
    func testCopyingAnotherFormatKeepsTheEntryAndPromotesIt() throws {
        let manager = makeManager(directory: makeDirectory())
        let color = try XCTUnwrap(manager.copy(blue))
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)
        manager.checkForChanges()

        manager.select(color, as: blue.rgb)
        manager.checkForChanges()

        XCTAssertEqual(pasteboard.string(forType: .string), "rgb(58, 123, 255)")
        // No rgb() card: the color card moved to the front instead.
        XCTAssertEqual(manager.entries.map(\.textValue), ["#3A7BFF", "newer"])
        XCTAssertEqual(manager.recentlySelectedID, color.id)
    }

    @MainActor
    func testCopiedHexTextBecomesAColorCard() {
        let manager = makeManager(directory: makeDirectory())
        pasteboard.clearContents()
        pasteboard.setString("#ff8800", forType: .string)
        manager.checkForChanges()
        XCTAssertEqual(manager.entries.first?.colorValue, ClipboardColor(red: 255, green: 136, blue: 0))
    }

    @MainActor
    func testColorEntriesSurviveRelaunch() throws {
        let directory = makeDirectory()
        let first = makeManager(directory: directory)
        let picked = try XCTUnwrap(first.copy(blue))
        first.togglePin(picked)
        first.flushSync()

        let second = makeManager(directory: directory)
        let restored = try XCTUnwrap(second.entries.first)
        XCTAssertEqual(restored.id, picked.id)
        XCTAssertEqual(restored.colorValue, blue)
        XCTAssertTrue(restored.isPinned)
    }
}
