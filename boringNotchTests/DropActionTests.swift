//
//  DropActionTests.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Covers the shelf's drop actions on generated files: which actions a drag
//  offers, image conversion between formats, background removal, zip and
//  unzip round trips, video re-wrapping, output naming, and that inputs are
//  never written to.
//

import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import boringNotch

final class DropActionTests: XCTestCase {

    private var fixtures: URL!
    /// Results to delete afterwards; each sits in a temporary folder of its own.
    private var outputs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtures)
        for output in outputs {
            try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
        }
        outputs = []
        fixtures = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeImage(
        named name: String,
        type: UTType,
        width: Int = 64,
        height: Int = 48,
        transparentLeftHalf: Bool = false,
        properties: [CFString: Any] = [:],
        in directory: URL? = nil
    ) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if transparentLeftHalf {
            context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        return try write(image, named: name, type: type, properties: properties, in: directory ?? fixtures)
    }

    private func write(_ image: CGImage, named name: String, type: UTType, properties: [CFString: Any] = [:], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Something for Vision to pick out: a shaded ball resting on a plain,
    /// slightly graded backdrop.
    private func makeSubjectScene(named name: String) throws -> URL {
        let size = 512
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let backdrop = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0.93, alpha: 1), CGColor(gray: 0.82, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        context.drawLinearGradient(backdrop, start: .zero, end: CGPoint(x: 0, y: size), options: [])

        let center = CGPoint(x: 256, y: 240)
        let ball = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(red: 1, green: 0.45, blue: 0.35, alpha: 1), CGColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - 130, y: center.y - 130, width: 260, height: 260))
        context.clip()
        context.drawRadialGradient(
            ball,
            startCenter: CGPoint(x: center.x - 50, y: center.y + 50), startRadius: 10,
            endCenter: center, endRadius: 140,
            options: []
        )
        context.restoreGState()

        let image = try XCTUnwrap(context.makeImage())
        return try write(image, named: name, type: .jpeg, in: fixtures)
    }

    @discardableResult
    private func writeText(_ text: String, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func run(_ action: DropAction, on inputs: [URL]) async throws -> [URL] {
        let results = try await DropActionService.run(action, on: inputs)
        outputs += results
        return results
    }

    /// For actions that make exactly one result.
    private func runOne(_ action: DropAction, on inputs: [URL]) async throws -> URL {
        let results = try await run(action, on: inputs)
        XCTAssertEqual(results.count, 1)
        return try XCTUnwrap(results.first)
    }

    private func imageType(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// RGBA of one pixel, with y counted from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    private func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func relativeContents(of directory: URL) throws -> [String: String] {
        var contents: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
            contents[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return contents
    }

    // MARK: - What a drag offers

    func testImagesOfferConvertRemoveBackgroundAndZip() {
        let availability = DropActionAvailability(contentTypes: [.jpeg, .png])
        XCTAssertEqual(availability.actions, [.convert, .removeBackground, .zip])
        XCTAssertEqual(availability.formats, [.jpeg, .png, .heic, .tiff])
    }

    func testConvertLeavesOutTheFormatEverythingAlreadyIs() {
        XCTAssertEqual(DropActionAvailability(contentTypes: [.png, .png]).formats, [.jpeg, .heic, .tiff])
        XCTAssertEqual(DropActionAvailability(contentTypes: [.jpeg]).formats.first, .png,
                       "A quick drop on Convert should never produce the format it started as")
        XCTAssertEqual(DropActionAvailability(contentTypes: [.quickTimeMovie]).formats, [.mp4, .m4a])
    }

    func testArchivesMoviesAudioAndOtherFiles() {
        XCTAssertEqual(DropActionAvailability(contentTypes: [.zip]).actions, [.unzip, .zip])
        XCTAssertEqual(DropActionAvailability(contentTypes: [.mpeg4Movie]).actions, [.convert, .zip])
        XCTAssertEqual(DropActionAvailability(contentTypes: [.mp3]).formats, [.m4a])
        // Already M4A: nothing left to convert to.
        XCTAssertEqual(DropActionAvailability(contentTypes: [UTType("com.apple.m4a-audio")!]).actions, [.zip])
        XCTAssertEqual(DropActionAvailability(contentTypes: [.pdf, .folder]).actions, [.zip])
        // SVG is an image type ImageIO can't decode.
        XCTAssertEqual(DropActionAvailability(contentTypes: [.svg]).actions, [.zip])
        // Images and a zip together only share Zip.
        XCTAssertEqual(DropActionAvailability(contentTypes: [.png, .zip]).actions, [.zip])
    }

    func testTextAndLinksOfferNothing() {
        XCTAssertTrue(DropActionAvailability(contentTypes: [nil]).isEmpty)
        XCTAssertTrue(DropActionAvailability(contentTypes: [.png, nil]).isEmpty)
        XCTAssertTrue(DropActionAvailability(contentTypes: []).isEmpty)
    }

    func testReadsFinderStyleDragPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DropActionTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        // Finder's legacy list of real paths, beside its unreadable reference URLs.
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.declareTypes([filenames], owner: nil)
        pasteboard.setPropertyList(["/Users/someone/Desktop/Photo.HEIC", "/Users/someone/Desktop/Shot.png"], forType: filenames)
        XCTAssertEqual(DropActionAvailability.forDrag(on: pasteboard).actions, [.convert, .removeBackground, .zip])

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("file:///Users/someone/Downloads/Bundle.zip", forType: .fileURL)
        pasteboard.writeObjects([item])
        XCTAssertEqual(DropActionAvailability.forDrag(on: pasteboard).actions, [.unzip, .zip])

        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        XCTAssertTrue(DropActionAvailability.forDrag(on: pasteboard).isEmpty)
    }

    // MARK: - Convert

    func testConvertsPNGToEachImageFormat() async throws {
        let input = try makeImage(named: "Photo.png", type: .png)
        for format in [DropConversionFormat.jpeg, .heic, .tiff] {
            let url = try await runOne(.convert(format), on: [input])
            XCTAssertEqual(url.lastPathComponent, "Photo.\(format.fileExtension)")
            XCTAssertEqual(imageType(at: url), format.utType.identifier)
            let converted = try image(at: url)
            XCTAssertEqual(converted.width, 64)
            XCTAssertEqual(converted.height, 48)
        }
    }

    func testConvertsJPEGToPNG() async throws {
        let input = try makeImage(named: "Holiday.jpg", type: .jpeg)
        let url = try await runOne(.convert(.png), on: [input])
        XCTAssertEqual(url.lastPathComponent, "Holiday.png")
        XCTAssertEqual(imageType(at: url), UTType.png.identifier)
    }

    func testJPEGFlattensTransparencyOntoWhite() async throws {
        let input = try makeImage(named: "Logo.png", type: .png, transparentLeftHalf: true)
        let url = try await runOne(.convert(.jpeg), on: [input])
        let converted = try image(at: url)
        let transparentArea = try pixel(converted, x: 4, y: 24)
        XCTAssertGreaterThan(transparentArea[0], 240, "Transparent pixels should turn white, not black")
        XCTAssertGreaterThan(transparentArea[2], 240)
        let opaqueArea = try pixel(converted, x: 60, y: 24)
        XCTAssertGreaterThan(opaqueArea[2], opaqueArea[0], "Opaque pixels keep their color")
    }

    func testConversionBakesInEXIFRotation() async throws {
        // Stored 64×48 but tagged "rotate 90° clockwise" (orientation 6).
        let input = try makeImage(named: "Portrait.jpg", type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let url = try await runOne(.convert(.png), on: [input])
        let converted = try image(at: url)
        XCTAssertEqual(converted.width, 48)
        XCTAssertEqual(converted.height, 64)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testEveryImageFormatIsWritable() {
        for format in DropConversionFormat.imageFormats {
            XCTAssertTrue(ImageProcessingService.writableImageTypes.contains(format.utType.identifier), "\(format) isn't writable")
        }
    }

    // MARK: - Remove background

    func testRemoveBackgroundMakesTransparentPNG() async throws {
        let input = try makeSubjectScene(named: "Ball.jpg")
        let url = try await runOne(.removeBackground, on: [input])
        XCTAssertEqual(url.lastPathComponent, "Ball (background removed).png")
        XCTAssertEqual(imageType(at: url), UTType.png.identifier)

        let cutout = try image(at: url)
        XCTAssertEqual(cutout.width, 512)
        XCTAssertEqual(cutout.height, 512)
        XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(cutout.alphaInfo), "The PNG needs an alpha channel")
        XCTAssertEqual(try pixel(cutout, x: 8, y: 8)[3], 0, "The backdrop should be transparent")
        XCTAssertGreaterThan(try pixel(cutout, x: 256, y: 272)[3], 200, "The subject should stay opaque")
    }

    // MARK: - Zip and unzip

    func testZipUnzipRoundTripWithSeveralItems() async throws {
        let a = try writeText("alpha", named: "a.txt", in: fixtures)
        let b = try writeText("bravo", named: "b.txt", in: fixtures)
        let folder = fixtures.appendingPathComponent("Folder", isDirectory: true)
        try writeText("charlie", named: "c.txt", in: folder)

        let archive = try await runOne(.zip, on: [a, b, folder])
        XCTAssertEqual(archive.lastPathComponent, "Archive.zip")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path), ["Archive.zip"],
                       "Only the archive should be left beside it — no staging copies")

        // Several top-level items come out in a folder named after the archive.
        let extracted = try await runOne(.unzip, on: [archive])
        XCTAssertEqual(extracted.lastPathComponent, "Archive")
        XCTAssertEqual(try relativeContents(of: extracted), [
            "a.txt": "alpha",
            "b.txt": "bravo",
            "Folder/c.txt": "charlie"
        ])
    }

    func testZippingOneFileUnzipsToThatFile() async throws {
        let input = try makeImage(named: "Photo.jpg", type: .jpeg)
        let archive = try await runOne(.zip, on: [input])
        XCTAssertEqual(archive.lastPathComponent, "Photo.zip")

        let extracted = try await runOne(.unzip, on: [archive])
        XCTAssertEqual(extracted.lastPathComponent, "Photo.jpg")
        XCTAssertEqual(try digest(of: extracted), try digest(of: input))
    }

    func testZippingOneFolderKeepsItsWholeName() async throws {
        let folder = fixtures.appendingPathComponent("Project v1.2", isDirectory: true)
        try writeText("notes", named: "notes.md", in: folder)

        let archive = try await runOne(.zip, on: [folder])
        XCTAssertEqual(archive.lastPathComponent, "Project v1.2.zip")

        let extracted = try await runOne(.unzip, on: [archive])
        XCTAssertEqual(extracted.lastPathComponent, "Project v1.2")
        XCTAssertEqual(try relativeContents(of: extracted), ["notes.md": "notes"])
    }

    func testSameNamedFilesAreNumberedInsideTheArchive() async throws {
        let first = try writeText("one", named: "Notes.txt", in: fixtures.appendingPathComponent("One"))
        let second = try writeText("two", named: "Notes.txt", in: fixtures.appendingPathComponent("Two"))

        let archive = try await runOne(.zip, on: [first, second])
        let extracted = try await runOne(.unzip, on: [archive])
        XCTAssertEqual(try relativeContents(of: extracted), ["Notes.txt": "one", "Notes 2.txt": "two"])
    }

    func testUnzippingSomethingThatIsntAZipFails() async throws {
        let fake = try writeText("not really a zip", named: "Broken.zip", in: fixtures)
        do {
            _ = try await run(.unzip, on: [fake])
            XCTFail("Expected unzip to fail")
        } catch {
            XCTAssertEqual(error as? DropActionError, .archiveFailed)
        }
    }

    // MARK: - Video

    func testRewrapsMovieAsMP4() async throws {
        let movie = try await makeMovie(named: "Clip.mov")
        let url = try await runOne(.convert(.mp4), on: [movie])
        XCTAssertEqual(url.lastPathComponent, "Clip.mp4")

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
    }

    /// One second of solid frames, H.264 in a QuickTime container.
    private func makeMovie(named name: String) async throws -> URL {
        let url = fixtures.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame * 20), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    // MARK: - Naming and never overwriting

    func testOutputNames() {
        let photo = URL(fileURLWithPath: "/tmp/Photo.jpeg")
        let archive = URL(fileURLWithPath: "/tmp/Bundle.zip")
        XCTAssertEqual(DropActionService.outputName(for: .convert(.png), inputs: [photo]), "Photo.png")
        XCTAssertEqual(DropActionService.outputName(for: .convert(.jpeg), inputs: [URL(fileURLWithPath: "/tmp/Shot.HEIC")]), "Shot.jpg")
        XCTAssertEqual(DropActionService.outputName(for: .removeBackground, inputs: [photo]), "Photo (background removed).png")
        XCTAssertEqual(DropActionService.outputName(for: .zip, inputs: [photo]), "Photo.zip")
        XCTAssertEqual(DropActionService.outputName(for: .zip, inputs: [photo, archive]), "Archive.zip")
        XCTAssertEqual(DropActionService.outputName(for: .unzip, inputs: [archive]), "Bundle")
        XCTAssertEqual(DropActionService.outputName(for: .zip, inputs: [URL(fileURLWithPath: "/tmp/.env")]), ".env.zip")
    }

    func testUniqueURLNumbersTakenNamesLikeFinder() throws {
        XCTAssertEqual(DropActionService.uniqueURL(for: "Photo.jpg", in: fixtures).lastPathComponent, "Photo.jpg")
        try writeText("", named: "Photo.jpg", in: fixtures)
        XCTAssertEqual(DropActionService.uniqueURL(for: "Photo.jpg", in: fixtures).lastPathComponent, "Photo 2.jpg")
        try writeText("", named: "Photo 2.jpg", in: fixtures)
        XCTAssertEqual(DropActionService.uniqueURL(for: "Photo.jpg", in: fixtures).lastPathComponent, "Photo 3.jpg")
        try writeText("", named: "README", in: fixtures)
        XCTAssertEqual(DropActionService.uniqueURL(for: "README", in: fixtures).lastPathComponent, "README 2")
    }

    func testActionsNeverTouchTheirInputs() async throws {
        let png = try makeImage(named: "Same.png", type: .png)
        let text = try writeText("keep me", named: "Same.txt", in: fixtures)
        let before = try [digest(of: png), digest(of: text)]
        let fixtureListing = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted()

        var results: [URL] = []
        results += try await run(.convert(.png), on: [png])   // same format, same name
        results += try await run(.convert(.tiff), on: [png])
        results += try await run(.zip, on: [png])
        results += try await run(.zip, on: [png, text])
        results += try await run(.unzip, on: [try XCTUnwrap(results.last)])

        XCTAssertEqual(try [digest(of: png), digest(of: text)], before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted(), fixtureListing,
                       "Nothing should be written beside the inputs")
        for result in results {
            XCTAssertNotEqual(result.deletingLastPathComponent().standardizedFileURL, fixtures.standardizedFileURL)
        }
        XCTAssertEqual(Set(results.map { $0.deletingLastPathComponent() }).count, results.count,
                       "Every result gets a folder of its own")
    }
}
