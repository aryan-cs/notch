//
//  ImageProcessingService.swift
//  Notch
//
//  Created by Alexander on 2025-10-16.
//

import Foundation
import AppKit
import CoreImage
import CoreGraphics
import Vision
import PDFKit
import UniformTypeIdentifiers
import ImageIO

/// Options for image conversion
struct ImageConversionOptions {
    enum ImageFormat {
        case png, jpeg, heic, tiff, bmp

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            case .bmp: return .bmp
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }

    let format: ImageFormat
    let compressionQuality: Double // 0.0 to 1.0, only applies to JPEG/HEIC
    let maxDimension: CGFloat? // Max width or height, nil for no scaling
    let removeMetadata: Bool
}

/// Service for processing images (background removal, conversion, PDF creation)
@MainActor
final class ImageProcessingService {
    static let shared = ImageProcessingService()

    private init() {}
    private let ciContext = CIContext(options: nil)

    // MARK: - Remove Background

    /// Cuts the subject(s) out of the image at `url` with Vision and returns
    /// a PNG with a transparent background, the same size as the original.
    /// Synchronous and slow (Vision takes a moment), so call it off the main
    /// actor — `DropActionService` does.
    nonisolated static func backgroundRemovedPNG(from url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = uprightImage(from: source) else {
            throw ImageProcessingError.invalidImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ImageProcessingError.noSubjectFound
        }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)

        let input = CIImage(cgImage: image)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = input
        filter.maskImage = CIImage(cvPixelBuffer: mask)
        filter.backgroundImage = CIImage.empty()

        // Grayscale sources still need an RGB(A) canvas for the alpha channel.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = filter.outputImage,
              let cutout = CIContext().createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ImageProcessingError.backgroundRemovalFailed
        }

        return try encode(cutout, as: .png, properties: [:])
    }

    // MARK: - Re-encode (ImageIO)

    /// Image types ImageIO can write on this Mac.
    nonisolated static let writableImageTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// Re-encodes the first image in `url` as `type`, keeping its metadata
    /// and color profile. Pixels are copied untouched where possible; they're
    /// only redrawn to bake in a rotation the target might not honor, or to
    /// flatten transparency onto white for formats without alpha (JPEG).
    nonisolated static func encodedImage(from url: URL, as type: UTType, quality: Double = 0.9) throws -> Data {
        guard writableImageTypes.contains(type.identifier) else {
            throw ImageProcessingError.conversionFailed
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessingError.invalidImage
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(original.alphaInfo)
        let dropsAlpha = type.conforms(to: .jpeg)

        guard orientation != 1 || (hasAlpha && dropsAlpha) else {
            return try encode(source: source, as: type, properties: properties)
        }

        guard var image = uprightImage(from: source) else { throw ImageProcessingError.invalidImage }
        if hasAlpha && dropsAlpha {
            image = try flattenedOntoWhite(image)
        }
        // The pixels are upright now; a leftover tag would rotate them twice.
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return try encode(image, as: type, properties: properties)
    }

    nonisolated private static func encode(source: CGImageSource, as type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.conversionFailed
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.conversionFailed }
        return data as Data
    }

    nonisolated private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.conversionFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.conversionFailed }
        return data as Data
    }

    /// The first image at full size with its EXIF orientation applied.
    nonisolated private static func uprightImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func flattenedOntoWhite(_ image: CGImage) throws -> CGImage {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageProcessingError.conversionFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw ImageProcessingError.conversionFailed }
        return flattened
    }

    // MARK: - Convert Image

    /// Converts an image with specified options
    func convertImage(from url: URL, options: ImageConversionOptions) async throws -> URL? {
        guard var inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }

        // Scale image if needed
        if let maxDim = options.maxDimension {
            inputImage = scaleImage(inputImage, maxDimension: maxDim)
        }

        // Get image data based on format
        let imageData: Data?

        if options.removeMetadata {
            // Create new image without metadata
            guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImageProcessingError.invalidImage
            }

            let newImage = NSImage(cgImage: cgImage, size: inputImage.size)
            imageData = try convertToFormat(newImage, format: options.format, quality: options.compressionQuality)
        } else {
            imageData = try convertToFormat(inputImage, format: options.format, quality: options.compressionQuality)
        }

        guard let data = imageData else {
            throw ImageProcessingError.conversionFailed
        }

        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_converted.\(options.format.fileExtension)"

        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(data, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }

        return tempURL
    }

    private func convertToFormat(_ image: NSImage, format: ImageConversionOptions.ImageFormat, quality: Double) throws -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: quality
            ]
            return bitmap.representation(using: .jpeg, properties: properties)
        case .tiff:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)
            ]
            return bitmap.representation(using: .tiff, properties: properties)
        case .bmp:
            return bitmap.representation(using: .bmp, properties: [:])
        case .heic:
            // HEIC requires using CIContext
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]
            return context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: options)
        }
    }

    private func scaleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return image }

        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let srcMax = max(srcCG.width, srcCG.height)
        if CGFloat(srcMax) <= maxDimension {
            return image // no downscaling needed
        }

        let scale = maxDimension / CGFloat(srcMax)

        let ciImage = CIImage(cgImage: srcCG)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = ciImage
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0

        guard let output = lanczos.outputImage else {
            return image
        }

        // Preserve the source color space for exact color matching
        let colorSpace = srcCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

        // Render using the CIContext with matching color space
        guard let dstCG = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }

        return NSImage(cgImage: dstCG, size: NSSize(width: dstCG.width, height: dstCG.height))
    }

    // MARK: - Create PDF

    /// Creates a PDF from multiple image URLs
    func createPDF(from imageURLs: [URL], outputName: String? = nil) async throws -> URL? {
        guard !imageURLs.isEmpty else {
            throw ImageProcessingError.noImagesProvided
        }

        let pdfDocument = PDFDocument()

        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }

            let pdfPage = PDFPage(image: image)
            if let page = pdfPage {
                pdfDocument.insert(page, at: index)
            }
        }

        guard pdfDocument.pageCount > 0 else {
            throw ImageProcessingError.pdfCreationFailed
        }

        // Create temporary file
        let name = outputName ?? "images_\(Date().timeIntervalSince1970).pdf"
        let pdfName = name.hasSuffix(".pdf") ? name : "\(name).pdf"

        guard let pdfData = pdfDocument.dataRepresentation() else {
            throw ImageProcessingError.pdfCreationFailed
        }

        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(pdfData, suggestedName: pdfName)
        ) else {
            throw ImageProcessingError.saveFailed
        }

        return tempURL
    }

    // MARK: - Helper Methods

    /// Checks if a URL is an image file
    func isImageFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}

// MARK: - Errors

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case backgroundRemovalFailed
    case noSubjectFound
    case conversionFailed
    case pdfCreationFailed
    case noImagesProvided
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The file is not a valid image"
        case .backgroundRemovalFailed:
            return "Failed to remove background from image"
        case .noSubjectFound:
            return "No subject was found to separate from the background"
        case .conversionFailed:
            return "Failed to convert image format"
        case .pdfCreationFailed:
            return "Failed to create PDF from images"
        case .noImagesProvided:
            return "No images were provided"
        case .saveFailed:
            return "Failed to save processed file"
        }
    }
}
