//
//  FaceRecognizer.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face identity on an RGB webcam, the way Glance/FaceUnlock (and ultimately
//  Apple's own matcher) do it: detect the face with Vision, align it to the
//  ArcFace 112x112 canonical template using five landmarks, run a face
//  embedding model, L2-normalise, and compare by cosine similarity. No frame is
//  kept — only the 512-d embedding.
//
//  Model: AdaFace IR-50 (WebFace4M), converted to Core ML — quality-adaptive,
//  more robust in varied/low lighting than a plain ArcFace. Input `data`
//  MLMultiArray [1,3,112,112] float32 (NCHW, RGB, value = pixel/127.5 - 1).
//  Output `embedding` [1,512] float32.
//

import CoreImage
import CoreML
import Foundation
import Vision

/// A single detection in one frame: what the recognizer saw, used both to embed
/// and (via landmarks/pose) to judge liveness.
struct FaceDetection {
    let boundingBox: CGRect          // Vision-normalised (bottom-left origin)
    let roll: Double                 // radians
    let yaw: Double                  // radians
    let pitch: Double                // radians
    let landmarks: VNFaceLandmarks2D?
    /// L2-normalised 512-d identity embedding, if alignment + model succeeded.
    let embedding: [Float]?
    /// Crop brightness and alignment fit, for the diagnostic log only.
    let diagnostics: String
}

final class FaceRecognizer {
    /// Bump when the model or crop preprocessing changes so stale enrollments
    /// (embeddings made under a different model/preprocessing) are invalidated.
    /// v3 = AdaFace IR-50 (more robust in varied lighting than AuraFace).
    static let preprocessingVersion = 3

    private var model: MLModel?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // ArcFace canonical 5-point template in a 112x112, top-left-origin crop.
    private let templatePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),   // left eye
        CGPoint(x: 73.5318, y: 51.5014),   // right eye
        CGPoint(x: 56.0252, y: 71.7366),   // nose tip
        CGPoint(x: 41.5493, y: 92.3655),   // left mouth corner
        CGPoint(x: 70.7299, y: 92.2041),   // right mouth corner
    ]

    enum LoadError: Error { case modelMissing }

    init() {}

    /// Loads the bundled model. Xcode compiles the .mlpackage to an
    /// `auraface_v1.mlmodelc`; fall back to an uncompiled package during dev.
    @discardableResult
    func loadModelIfNeeded() throws -> Bool {
        if model != nil { return true }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine when available
        let url = Bundle.main.url(forResource: "adaface_ir50", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "adaface_ir50", withExtension: "mlpackage")
        guard let url else { throw LoadError.modelMissing }
        let loadURL: URL
        if url.pathExtension == "mlpackage" {
            loadURL = try MLModel.compileModel(at: url)
        } else {
            loadURL = url
        }
        model = try MLModel(contentsOf: loadURL, configuration: config)
        return true
    }

    // MARK: - Detection + embedding

    /// Detects the largest face in a frame and, when it can align it, returns
    /// its embedding alongside the geometry liveness needs. `pixelBuffer` is a
    /// camera frame; nothing is retained.
    func process(pixelBuffer: CVPixelBuffer) -> FaceDetection? {
        // Rectangles first: unlike the landmarks request it reports head pose
        // (roll/yaw/pitch), which motion liveness needs. Landmarks then run on
        // just that face.
        let rectangles = VNDetectFaceRectanglesRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([rectangles])) != nil,
              let pose = rectangles.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }
        landmarks.inputFaceObservations = [pose]
        guard (try? handler.perform([landmarks])) != nil, let face = landmarks.results?.first else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let aligned = alignedEmbedding(face: face, pixelBuffer: pixelBuffer,
                                       imageWidth: width, imageHeight: height)
        return FaceDetection(
            boundingBox: face.boundingBox,
            roll: pose.roll?.doubleValue ?? 0,
            yaw: pose.yaw?.doubleValue ?? 0,
            pitch: pose.pitch?.doubleValue ?? 0,
            landmarks: face.landmarks,
            embedding: aligned?.embedding,
            diagnostics: aligned?.diagnostics ?? "unaligned"
        )
    }

    private func alignedEmbedding(face: VNFaceObservation, pixelBuffer: CVPixelBuffer,
                                  imageWidth: Int, imageHeight: Int) -> (embedding: [Float]?, diagnostics: String)? {
        guard let model, let src = fivePoints(from: face, width: imageWidth, height: imageHeight),
              let affine = similarityTransform(from: src, to: templatePoints),
              let aligned = warp(pixelBuffer: pixelBuffer, affine: affine) else { return nil }
        guard let (array, brightness) = multiArray(from: aligned) else { return nil }
        let diagnostics = alignmentDiagnostics(src: src, affine: affine, brightness: brightness)
        guard let out = try? model.prediction(from: FaceModelInput(data: array)),
              let embeddingArray = out.featureValue(for: "embedding")?.multiArrayValue else { return (nil, diagnostics) }
        return (normalize(embeddingArray), diagnostics)
    }

    /// For the log: crop brightness (the camera's auto-exposure ramps up over
    /// the first second) and how well the five points fit the template, as RMS
    /// px in the 112 crop (a good alignment is ~3–4 px).
    private func alignmentDiagnostics(src: [CGPoint], affine: CGAffineTransform, brightness: Double) -> String {
        let squares = zip(src, templatePoints).map { p, q -> Double in
            let m = p.applying(affine)
            return Double((m.x - q.x) * (m.x - q.x) + (m.y - q.y) * (m.y - q.y))
        }
        return String(format: "crop=%.0f fit=%.1fpx", brightness, sqrt(squares.reduce(0, +) / Double(squares.count)))
    }

    // MARK: - Five-point landmarks (top-left pixel space)

    /// Left eye, right eye, nose tip, left + right mouth corners, in top-left
    /// pixel coordinates. Returns nil if Vision didn't give enough landmarks.
    private func fivePoints(from face: VNFaceObservation, width: Int, height: Int) -> [CGPoint]? {
        guard let lm = face.landmarks else { return nil }
        let box = face.boundingBox

        // Vision landmark points are normalised within the face box, bottom-left
        // origin; map to top-left pixel space.
        func toPixel(_ p: CGPoint) -> CGPoint {
            let nx = box.origin.x + p.x * box.size.width
            let ny = box.origin.y + p.y * box.size.height
            return CGPoint(x: nx * CGFloat(width), y: (1 - ny) * CGFloat(height))
        }
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return toPixel(CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count)))
        }

        let leftEye = (lm.leftPupil?.normalizedPoints.first).map(toPixel) ?? centroid(lm.leftEye)
        let rightEye = (lm.rightPupil?.normalizedPoints.first).map(toPixel) ?? centroid(lm.rightEye)
        guard let leftEye, let rightEye else { return nil }

        // Nose tip: the lowest point of the nose crest.
        let nose = lm.nose?.normalizedPoints.min(by: { $0.y < $1.y }).map(toPixel) ?? centroid(lm.nose)
        guard let nose else { return nil }

        // Mouth corners: extreme x of the outer lips.
        guard let lips = lm.outerLips?.normalizedPoints, lips.count >= 2,
              let leftMouthN = lips.min(by: { $0.x < $1.x }),
              let rightMouthN = lips.max(by: { $0.x < $1.x }) else { return nil }
        let leftMouth = toPixel(leftMouthN)
        let rightMouth = toPixel(rightMouthN)

        return [leftEye, rightEye, nose, leftMouth, rightMouth]
    }

    // MARK: - Least-squares 2D similarity transform (src -> dst)

    /// Solves for (a, b, tx, ty) in X = a*x - b*y + tx, Y = b*x + a*y + ty over
    /// all point pairs (a rotation+uniform-scale+translation, no reflection),
    /// returned as the affine [a -b tx; b a ty] mapping src space to dst space.
    private func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = Double(src.count)
        var Sx = 0.0, Sy = 0.0, SX = 0.0, SY = 0.0, Sxx = 0.0, SxX = 0.0, SxY = 0.0
        for i in 0..<src.count {
            let x = Double(src[i].x), y = Double(src[i].y)
            let X = Double(dst[i].x), Y = Double(dst[i].y)
            Sx += x; Sy += y; SX += X; SY += Y
            Sxx += x * x + y * y
            SxX += x * X + y * Y
            SxY += x * Y - y * X
        }
        // Normal equations M * [a b tx ty]^T = c.
        let M: [[Double]] = [
            [Sxx, 0,   Sx, Sy],
            [0,   Sxx, -Sy, Sx],
            [Sx,  -Sy, n,  0],
            [Sy,  Sx,  0,  n],
        ]
        let c = [SxX, SxY, SX, SY]
        guard let sol = solve4x4(M, c) else { return nil }
        let (a, b, tx, ty) = (sol[0], sol[1], sol[2], sol[3])
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    private func solve4x4(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var m = A.map { $0 }
        var v = b
        let n = 4
        for col in 0..<n {
            // Partial pivot.
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            m.swapAt(col, pivot); v.swapAt(col, pivot)
            let d = m[col][col]
            for c in col..<n { m[col][c] /= d }
            v[col] /= d
            for r in 0..<n where r != col {
                let f = m[r][col]
                guard f != 0 else { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                v[r] -= f * v[col]
            }
        }
        return v
    }

    // MARK: - Warp to 112x112 and pack into the model's input array

    /// Renders the frame into a 112x112 RGBA8 buffer such that the detected
    /// landmarks land on the ArcFace template, matching the affine (which is in
    /// top-left space; the context is flipped to top-left to match).
    private func warp(pixelBuffer: CVPixelBuffer, affine: CGAffineTransform) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let full = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let side = 112
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip to top-left origin, then apply the src->template transform, then
        // draw the full frame at its natural (top-left) rect.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(affine)
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: full.width, height: full.height))
        return ctx.makeImage()
    }

    /// The model input, plus the crop's mean brightness before normalisation.
    private func multiArray(from image: CGImage) -> (MLMultiArray, Double)? {
        let side = 112
        guard image.width == side, image.height == side,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let count = side * side

        // A webcam has no IR like Face ID, so normalising the crop for lighting
        // is the main lever we have. Pass 1: per-channel means over the crop.
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for y in 0..<side {
            let row = y * bytesPerRow
            for x in 0..<side {
                let px = row + x * 4
                sumR += Double(ptr[px]); sumG += Double(ptr[px + 1]); sumB += Double(ptr[px + 2])
            }
        }
        let n = Double(count)
        let meanR = sumR / n, meanG = sumG / n, meanB = sumB / n
        let gray = (meanR + meanG + meanB) / 3
        // Grey-world white balance kills a colour cast (e.g. a blue lamp); the
        // brightness term pulls dim or blown-out frames toward mid-grey. Gains
        // are clamped so noise in near-black frames isn't amplified wildly.
        func gain(_ mean: Double) -> Double { mean > 1 ? min(max(gray / mean, 0.5), 2.0) : 1 }
        let gR = gain(meanR), gG = gain(meanG), gB = gain(meanB)
        let brightness = gray > 1 ? min(max(128.0 / gray, 0.6), 1.8) : 1

        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32) else { return nil }
        let out = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * count)

        func norm(_ v: UInt8, _ g: Double) -> Float32 {
            let c = min(max(Double(v) * g * brightness, 0), 255)
            return Float32(c / 127.5 - 1)
        }
        for y in 0..<side {
            let row = y * bytesPerRow
            for x in 0..<side {
                let px = row + x * 4           // RGBA8, premultiplied (alpha = 255 here)
                let idx = y * side + x
                out[0 * count + idx] = norm(ptr[px], gR)       // channel 0 = R
                out[1 * count + idx] = norm(ptr[px + 1], gG)   // channel 1 = G
                out[2 * count + idx] = norm(ptr[px + 2], gB)   // channel 2 = B
            }
        }
        return (array, gray)
    }

    private func normalize(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
        var out = [Float](repeating: 0, count: count)
        var norm: Float = 0
        for i in 0..<count { norm += ptr[i] * ptr[i] }
        norm = max(sqrt(norm), 1e-10)
        for i in 0..<count { out[i] = ptr[i] / norm }
        return out
    }

    // MARK: - Comparison

    /// Cosine similarity of two L2-normalised embeddings (just a dot product).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }
}

/// Thin typed input wrapper so we don't depend on Xcode's model codegen.
private final class FaceModelInput: NSObject, MLFeatureProvider {
    let data: MLMultiArray
    init(data: MLMultiArray) { self.data = data }
    var featureNames: Set<String> { ["data"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == "data" ? MLFeatureValue(multiArray: data) : nil
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
