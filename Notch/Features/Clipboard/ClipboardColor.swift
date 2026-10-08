//
//  ClipboardColor.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A color in the clipboard history. There's no separate entry kind for
//  colors: the eyedropper copies hex text like any other copy, and any text
//  entry that is just a hex color is shown as a swatch. Everything here is
//  8-bit sRGB, which is what hex holds — sampled colors are converted to
//  sRGB first, so every format agrees with the hex that was copied.
//

import AppKit

struct ClipboardColor: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var isOpaque: Bool { alpha == 255 }

    /// Converts to sRGB first; colors outside it (a vivid P3 red, say) are
    /// clamped to its edge.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * 255).rounded())
        }
        self.init(
            red: byte(srgb.redComponent),
            green: byte(srgb.greenComponent),
            blue: byte(srgb.blueComponent),
            alpha: byte(srgb.alphaComponent)
        )
    }

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, in either case.
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = Array(hex.dropFirst())
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }

        // Short forms double each digit: #F80 is #FF8800.
        let expanded = digits.count <= 4 ? digits.flatMap { [$0, $0] } : digits
        let bytes = stride(from: 0, to: expanded.count, by: 2).compactMap {
            UInt8(String(expanded[$0...$0 + 1]), radix: 16)
        }
        self.init(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 255)
    }

    /// A copied string that is nothing but a hex color. Stricter than
    /// `init(hex:)` about the short forms, because "#123" copied on its own
    /// is far more often a GitHub issue than a color: those need a letter
    /// (#FA0) or one repeated digit (#333).
    static func detect(in text: String) -> ClipboardColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let color = ClipboardColor(hex: trimmed) else { return nil }
        let digits = trimmed.dropFirst()
        if digits.count <= 4,
           digits.allSatisfy(\.isNumber),
           Set(digits).count > 1 {
            return nil
        }
        return color
    }

    // MARK: Formats

    /// `#3A7BFF`, or `#3A7BFF80` when translucent.
    var hex: String {
        let components = isOpaque ? [red, green, blue] : [red, green, blue, alpha]
        return "#" + components.map {
            let digits = String($0, radix: 16, uppercase: true)
            return $0 < 0x10 ? "0" + digits : digits
        }.joined()
    }

    var rgb: String { "rgb(\(red), \(green), \(blue))" }

    var rgba: String { "rgba(\(red), \(green), \(blue), \(Self.decimal(unit(alpha), places: 2)))" }

    /// `hsl(220, 100%, 61%)`, or `hsla(…)` when translucent.
    var hsl: String {
        let (hue, saturation, lightness) = hslComponents
        let values = "\(hue), \(saturation)%, \(lightness)%"
        return isOpaque ? "hsl(\(values))" : "hsla(\(values), \(Self.decimal(unit(alpha), places: 2)))"
    }

    /// `Color(red:green:blue:)` is sRGB. Three places are enough to land on
    /// the same 8-bit value again.
    var swiftUI: String {
        let opacity = isOpaque ? "" : ", opacity: \(Self.decimal(unit(alpha), places: 3))"
        return "Color(red: \(code(red)), green: \(code(green)), blue: \(code(blue))\(opacity))"
    }

    var nsColor: String {
        "NSColor(srgbRed: \(code(red)), green: \(code(green)), blue: \(code(blue)), alpha: \(Self.decimal(unit(alpha), places: 3)))"
    }

    /// Hue in degrees, saturation and lightness in percent, each rounded.
    var hslComponents: (hue: Int, saturation: Int, lightness: Int) {
        let r = unit(red), g = unit(green), b = unit(blue)
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maximum {
        case r: hue = (g - b) / delta
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        return (
            Int(hue.rounded()) % 360,
            Int((saturation * 100).rounded()),
            Int((lightness * 100).rounded())
        )
    }

    private func unit(_ component: UInt8) -> Double {
        Double(component) / 255
    }

    private func code(_ component: UInt8) -> String {
        Self.decimal(unit(component), places: 3)
    }

    /// Fixed-point without trailing zeros: 1, 0.5, 0.227. `String(format:)`
    /// isn't localized, so it's always a dot.
    private static func decimal(_ value: Double, places: Int) -> String {
        var string = String(format: "%.\(places)f", value)
        while string.contains("."), string.hasSuffix("0") {
            string.removeLast()
        }
        if string.hasSuffix(".") {
            string.removeLast()
        }
        return string
    }
}
