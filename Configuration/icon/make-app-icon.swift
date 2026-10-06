// Usage: Configuration/icon/make-app-icon.sh <source-image> [--no-logo] [--threshold 0.5]   (the wrapper compiles this file with `xcrun swiftc` and runs it)
//
// Turns a macOS-style "squircle" icon image into the AppIcon.appiconset PNGs (16 ... 1024 px) and the
// matching `logo2` image used by onboarding/settings. The source may sit on a white or transparent
// background with a soft drop shadow: the squircle is located with sub-pixel precision, everything
// outside it becomes fully transparent, and the artwork is re-masked to Apple's continuous-corner icon
// shape (824x824 artwork centred on a 1024x1024 canvas, ~185 px corner radius). Assumes the icon has a
// dark outer border (any edge that clearly contrasts with the background works).

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apple macOS icon grid (1024 px canvas units)

let canvas = 1024.0
let artworkInset = 100.0
let artworkSize = 824.0
let cornerRadius = 185.4

let iconEntries: [(file: String, size: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1), ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1), ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1), ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1), ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1), ("icon_512x512@2x.png", 512, 2),
]

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

let usage = """
usage: make-app-icon <source-image> --iconset <AppIcon.appiconset> [--logo <x.imageset> | --no-logo] [--threshold 0..1]
  --threshold  luminance above which a pixel counts as background when flood-filling from the image
               edges (default 0.5; raise it if a dark drop shadow is mistaken for the icon)
"""

final class Bitmap {
    let ctx: CGContext
    let width: Int
    let height: Int
    let rowBytes: Int
    let px: UnsafeMutablePointer<UInt8>

    init(_ width: Int, _ height: Int, space: CGColorSpace, alpha: CGImageAlphaInfo) {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: alpha.rawValue),
              let data = ctx.data
        else { fail("cannot create a \(width)x\(height) bitmap") }
        self.ctx = ctx
        self.width = width
        self.height = height
        self.rowBytes = ctx.bytesPerRow
        self.px = data.assumingMemoryBound(to: UInt8.self)
    }

    var image: CGImage {
        guard let image = ctx.makeImage() else { fail("cannot snapshot bitmap") }
        return image
    }
}

/// Apple's continuous-corner ("squircle") rounded rectangle, as used for app icons.
func iconPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func median(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(sorted.count - 1, max(0, index))]
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

// MARK: - Arguments

setvbuf(stdout, nil, _IOLBF, 0) // keep stdout and stderr (warnings) in order

var sourcePath: String?
var iconsetPath: String?
var logoPath: String?
var noLogo = false
var threshold: Float = 0.5

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--iconset": iconsetPath = args.next()
    case "--logo": logoPath = args.next()
    case "--no-logo": noLogo = true
    case "--threshold":
        guard let value = args.next().flatMap(Float.init), value > 0, value < 1 else { fail("--threshold needs a value between 0 and 1") }
        threshold = value
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\(usage)") }
        sourcePath = arg
    }
}
guard let sourcePath, let iconsetPath else { fail(usage) }
if noLogo { logoPath = nil }

// MARK: - Load source

guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else { fail("cannot read image \(sourcePath)") }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
// Keep the source's own RGB colour space (e.g. Display P3 screenshots) so colours are not clipped.
let space: CGColorSpace = {
    if let cs = source.colorSpace, cs.model == .rgb,
       CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) != nil {
        return cs
    }
    return srgb
}()

let srcW = source.width, srcH = source.height
print("source: \(srcW)x\(srcH) px (\(space.name.map { $0 as String } ?? "custom colour space"))")

// Analysis buffer: source composited over white, padded so the flood fill always starts outside the icon.
let pad = 4
let w = srcW + 2 * pad, h = srcH + 2 * pad, n = w * h
let analysis = Bitmap(w, h, space: space, alpha: .premultipliedLast)
analysis.ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
analysis.ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
analysis.ctx.draw(source, in: CGRect(x: pad, y: pad, width: srcW, height: srcH))

var red = [Float](repeating: 0, count: n), green = red, blue = red, lum = red
for y in 0..<h {
    for x in 0..<w {
        let p = analysis.px + y * analysis.rowBytes + x * 4
        let i = y * w + x
        red[i] = Float(p[0]) / 255
        green[i] = Float(p[1]) / 255
        blue[i] = Float(p[2]) / 255
        lum[i] = 0.2126 * red[i] + 0.7152 * green[i] + 0.0722 * blue[i]
    }
}

@inline(__always) func forEachNeighbour(_ i: Int, _ body: (Int) -> Void) {
    let x = i % w, y = i / w
    if x > 0 { body(i - 1) }
    if x < w - 1 { body(i + 1) }
    if y > 0 { body(i - w) }
    if y < h - 1 { body(i + w) }
}

// MARK: - Segment: background = light pixels reachable from the edges

var outside = [Bool](repeating: false, count: n)
var queue = [Int]()
queue.reserveCapacity(n)
func seedOutside(_ i: Int) {
    if !outside[i] && lum[i] > threshold {
        outside[i] = true
        queue.append(i)
    }
}
for x in 0..<w { seedOutside(x); seedOutside((h - 1) * w + x) }
for y in 0..<h { seedOutside(y * w); seedOutside(y * w + w - 1) }
var head = 0
while head < queue.count {
    let i = queue[head]; head += 1
    forEachNeighbour(i, seedOutside)
}

// Keep only the largest non-background blob (drops stray specks, text, etc.).
var label = [Int32](repeating: -1, count: n)
var bestLabel: Int32 = -1, bestCount = 0, nextLabel: Int32 = 0
for start in 0..<n where !outside[start] && label[start] < 0 {
    queue.removeAll(keepingCapacity: true)
    queue.append(start); label[start] = nextLabel
    head = 0
    while head < queue.count {
        let i = queue[head]; head += 1
        forEachNeighbour(i) { j in
            if !outside[j] && label[j] < 0 { label[j] = nextLabel; queue.append(j) }
        }
    }
    if queue.count > bestCount { bestCount = queue.count; bestLabel = nextLabel }
    nextLabel += 1
}
guard bestCount > n / 20 else {
    fail("could not find the icon: no large dark-edged shape against a light background (try --threshold)")
}
for i in 0..<n where !outside[i] && label[i] != bestLabel { outside[i] = true }

/// 4-connected distance (capped) from the `from` set into the complement.
func distance(fromOutside: Bool, cap: UInt8) -> [UInt8] {
    var dist = [UInt8](repeating: UInt8.max, count: n)
    queue.removeAll(keepingCapacity: true)
    for i in 0..<n where outside[i] == fromOutside { dist[i] = 0; queue.append(i) }
    head = 0
    while head < queue.count {
        let i = queue[head]; head += 1
        let d = dist[i]
        if d >= cap { continue }
        forEachNeighbour(i) { j in
            if dist[j] == UInt8.max { dist[j] = d + 1; queue.append(j) }
        }
    }
    return dist
}
let distIn = distance(fromOutside: true, cap: 8)   // inside the icon: distance from the background
let distOut = distance(fromOutside: false, cap: 8) // in the background: distance from the icon

// MARK: - Edge colours

var cx0 = 0.0, cy0 = 0.0
for i in 0..<n where !outside[i] { cx0 += Double(i % w); cy0 += Double(i / w) }
cx0 /= Double(bestCount); cy0 /= Double(bestCount)

var borderR = [Float](), borderG = [Float](), borderB = [Float]()
for i in 0..<n where !outside[i] && (2...4).contains(distIn[i]) {
    borderR.append(red[i]); borderG.append(green[i]); borderB.append(blue[i])
}
guard let bR = median(borderR), let bG = median(borderG), let bB = median(borderB) else { fail("icon edge not found") }
let borderLum = 0.2126 * bR + 0.7152 * bG + 0.0722 * bB
print(String(format: "edge colour: rgb(%d, %d, %d)", Int(bR * 255), Int(bG * 255), Int(bB * 255)))

// Background colour just outside the edge, per 45-degree sector (drop shadows are uneven).
let sectors = 8
func sector(_ i: Int) -> Int {
    let angle = atan2(Double(i / w) - cy0, Double(i % w) - cx0) + .pi
    return min(sectors - 1, Int(angle / (2 * .pi) * Double(sectors)))
}
var ring = [[Int]](repeating: [], count: sectors), allRing = [Int]()
for i in 0..<n where outside[i] && (3...4).contains(distOut[i]) {
    ring[sector(i)].append(i); allRing.append(i)
}
func medianColour(_ pixels: [Int]) -> (r: Float, g: Float, b: Float, l: Float) {
    let r = median(pixels.map { red[$0] }) ?? 1, g = median(pixels.map { green[$0] }) ?? 1
    let b = median(pixels.map { blue[$0] }) ?? 1
    return (r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b)
}
let globalRef = medianColour(allRing)
let sectorRef = ring.map { $0.count >= 8 ? medianColour($0) : globalRef }
if globalRef.l - borderLum < 0.25 {
    warn(String(format: "low contrast between the icon edge (%.2f) and the background (%.2f); trimming may be imprecise", borderLum, globalRef.l))
}

// MARK: - Coverage (alpha) of the source squircle, and a cleaned, fully opaque copy

// Interior = 1, far background = 0; the 2-3 px around the edge get fractional coverage from how far
// each pixel sits between the edge colour and the local background (sub-pixel anti-aliasing).
var alpha = [Float](repeating: 0, count: n)
var isEdgeBand = [Bool](repeating: false, count: n)
for i in 0..<n {
    if !outside[i] && distIn[i] > 2 { alpha[i] = 1; continue }
    if outside[i] && distOut[i] > 3 { continue }
    let ref = sectorRef[sector(i)].l
    alpha[i] = min(1, max(0, (ref - lum[i]) / max(ref - borderLum, 0.05)))
    isEdgeBand[i] = true
}

// The cleaned image replaces the background with the edge colour: interior pixels are kept, far
// background becomes the edge colour, and anti-aliased edge pixels have their background share swapped
// for the edge colour (un-mixing pixel = a*fg + (1-a)*bg). Resampling and re-masking to a slightly
// different corner shape then never pulls in white or shadow.
let clean = Bitmap(w, h, space: space, alpha: .noneSkipLast)
func byte(_ v: Float) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
for y in 0..<h {
    for x in 0..<w {
        let i = y * w + x, a = alpha[i]
        let p = clean.px + y * clean.rowBytes + x * 4
        if isEdgeBand[i] && a > 0 {
            let bg = sectorRef[sector(i)]
            p[0] = byte(red[i] + (1 - a) * (bR - bg.r))
            p[1] = byte(green[i] + (1 - a) * (bG - bg.g))
            p[2] = byte(blue[i] + (1 - a) * (bB - bg.b))
        } else if a > 0 {
            p[0] = byte(red[i]); p[1] = byte(green[i]); p[2] = byte(blue[i])
        } else {
            p[0] = byte(bR); p[1] = byte(bG); p[2] = byte(bB)
        }
        p[3] = 255
    }
}

// MARK: - Fit the squircle's bounding square (sub-pixel, from coverage sums along the straight edges)

var bx0 = w, bx1 = -1, by0 = h, by1 = -1
for i in 0..<n where alpha[i] > 0.5 {
    let x = i % w, y = i / w
    bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
}
let cxi = (bx0 + bx1 + 1) / 2, cyi = (by0 + by1 + 1) / 2
let bandX = max(1, Int(0.12 * Double(bx1 - bx0 + 1))), bandY = max(1, Int(0.12 * Double(by1 - by0 + 1)))
var tops = [Double](), bottoms = [Double](), lefts = [Double](), rights = [Double]()
for x in (cxi - bandX)...(cxi + bandX) {
    var above = 0.0, below = 0.0
    for y in 0..<cyi { above += Double(alpha[y * w + x]) }
    for y in cyi..<h { below += Double(alpha[y * w + x]) }
    tops.append(Double(cyi) - above); bottoms.append(Double(cyi) + below)
}
for y in (cyi - bandY)...(cyi + bandY) {
    var before = 0.0, after = 0.0
    for x in 0..<cxi { before += Double(alpha[y * w + x]) }
    for x in cxi..<w { after += Double(alpha[y * w + x]) }
    lefts.append(Double(cxi) - before); rights.append(Double(cxi) + after)
}
// Outer-most quartile: robust to a notch or a slightly rounder corner reaching into the band.
let top = percentile(tops, 0.25), bottom = percentile(bottoms, 0.75)
let left = percentile(lefts, 0.25), right = percentile(rights, 0.75)
let side = ((right - left) + (bottom - top)) / 2
let boxX = (left + right) / 2 - side / 2, boxY = (top + bottom) / 2 - side / 2
print(String(format: "squircle: %.1f x %.1f px at (%.1f, %.1f) in the source", right - left, bottom - top, left - Double(pad), top - Double(pad)))
if abs((right - left) - (bottom - top)) / side > 0.03 {
    warn("the detected shape is not square; it will be fitted as a square")
}

// How well the source's own corners match Apple's shape (informational).
do {
    let mask = Bitmap(w, h, space: CGColorSpaceCreateDeviceGray(), alpha: .none)
    mask.ctx.setFillColor(gray: 1, alpha: 1)
    mask.ctx.addPath(iconPath(in: CGRect(x: boxX, y: Double(h) - boxY - side, width: side, height: side),
                              radius: cornerRadius / artworkSize * side))
    mask.ctx.fillPath()
    var maskSum = 0.0, alphaSum = 0.0, filled = 0.0, clipped = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let m = Double(mask.px[y * mask.rowBytes + x]) / 255, a = Double(alpha[y * w + x])
            maskSum += m; alphaSum += a
            filled += max(0, m - a); clipped += max(0, a - m)
        }
    }
    print(String(format: "shape match vs Apple squircle: %.2f%% of the mask padded with edge colour, %.2f%% of the source clipped",
                 100 * filled / maskSum, 100 * clipped / alphaSum))
}

let artworkPx = side
if artworkPx < artworkSize {
    let upscaled = iconEntries.filter { Double($0.size * $0.scale) * artworkSize / canvas > artworkPx + 0.5 }
        .map { "\($0.size)x\($0.size)@\($0.scale)x" }
    warn(String(format: "the squircle in the source is only %.0f px wide but the 1024 px icon needs %.0f px of artwork; "
                + "%@ will be upscaled (x%.2f at 1024) and look soft. Use a source of at least 1024 px for crisp results.",
                artworkPx, artworkSize, upscaled.joined(separator: ", "), artworkSize / artworkPx))
}

// MARK: - Render

// Opaque 1024 master: artwork mapped onto Apple's 824 px grid square; edge colour everywhere else.
let master = Bitmap(Int(canvas), Int(canvas), space: space, alpha: .noneSkipLast)
master.ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(bR), CGFloat(bG), CGFloat(bB), 1])!)
master.ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
master.ctx.interpolationQuality = .high
let scale = artworkSize / side
let imageTop = artworkInset - boxY * scale
master.ctx.draw(clean.image, in: CGRect(x: artworkInset - boxX * scale, y: canvas - imageTop - Double(h) * scale,
                                        width: Double(w) * scale, height: Double(h) * scale))

/// Downscales the opaque master (Lanczos) and applies an anti-aliased squircle mask at the target size,
/// so every size gets a crisp edge and fully transparent surroundings.
func renderIcon(pixels size: Int) -> CGImage {
    var scaled = master
    if size != master.width {
        scaled = Bitmap(size, size, space: space, alpha: .noneSkipLast)
        var src = vImage_Buffer(data: master.px, height: vImagePixelCount(master.height),
                                width: vImagePixelCount(master.width), rowBytes: master.rowBytes)
        var dst = vImage_Buffer(data: scaled.px, height: vImagePixelCount(size),
                                width: vImagePixelCount(size), rowBytes: scaled.rowBytes)
        let err = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        guard err == kvImageNoError else { fail("vImageScale failed (\(err))") }
    }
    let k = Double(size) / canvas
    let mask = Bitmap(size, size, space: CGColorSpaceCreateDeviceGray(), alpha: .none)
    mask.ctx.setFillColor(gray: 1, alpha: 1)
    mask.ctx.addPath(iconPath(in: CGRect(x: artworkInset * k, y: artworkInset * k, width: artworkSize * k, height: artworkSize * k),
                              radius: cornerRadius * k))
    mask.ctx.fillPath()

    let out = Bitmap(size, size, space: space, alpha: .premultipliedLast)
    for y in 0..<size {
        for x in 0..<size {
            let m = UInt32(mask.px[y * mask.rowBytes + x])
            let s = scaled.px + y * scaled.rowBytes + x * 4
            let o = out.px + y * out.rowBytes + x * 4
            for c in 0..<3 { o[c] = UInt8((UInt32(s[c]) * m + 127) / 255) }
            o[3] = UInt8(m)
        }
    }
    return out.image
}

// MARK: - Write the asset catalog

let fm = FileManager.default
let iconsetURL = URL(fileURLWithPath: iconsetPath)
try? fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

var rendered = [Int: CGImage]()
for entry in iconEntries {
    let pixels = entry.size * entry.scale
    let image = rendered[pixels] ?? renderIcon(pixels: pixels)
    rendered[pixels] = image
    writePNG(image, to: iconsetURL.appendingPathComponent(entry.file))
}

// Remove PNGs from a previous icon that are no longer referenced.
let keep = Set(iconEntries.map(\.file))
for file in (try? fm.contentsOfDirectory(atPath: iconsetPath)) ?? [] where file.lowercased().hasSuffix(".png") && !keep.contains(file) {
    try? fm.removeItem(at: iconsetURL.appendingPathComponent(file))
}

let contents: [String: Any] = [
    "images": iconEntries.map { ["filename": $0.file, "idiom": "mac", "scale": "\($0.scale)x", "size": "\($0.size)x\($0.size)"] },
    "info": ["author": "xcode", "version": 1],
]
var json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
json.append(contentsOf: Array("\n".utf8))
try json.write(to: iconsetURL.appendingPathComponent("Contents.json"))
print("wrote \(iconEntries.count) icons to \(iconsetPath)")

// The in-app logo image (onboarding welcome screen, settings) is the same 1024 px icon.
if let logoPath {
    let logoURL = URL(fileURLWithPath: logoPath)
    let contentsURL = logoURL.appendingPathComponent("Contents.json")
    var filename = "AppIcon.png"
    if let data = try? Data(contentsOf: contentsURL),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let images = object["images"] as? [[String: Any]],
       let existing = images.compactMap({ $0["filename"] as? String }).first {
        filename = existing
    } else {
        try? fm.createDirectory(at: logoURL, withIntermediateDirectories: true)
        let logoContents: [String: Any] = ["images": [["filename": filename, "idiom": "universal"]],
                                           "info": ["author": "xcode", "version": 1]]
        var data = try JSONSerialization.data(withJSONObject: logoContents, options: [.prettyPrinted, .sortedKeys])
        data.append(contentsOf: Array("\n".utf8))
        try data.write(to: contentsURL)
    }
    writePNG(rendered[1024] ?? renderIcon(pixels: 1024), to: logoURL.appendingPathComponent(filename))
    print("wrote \(logoPath)/\(filename)")
}
