//
//  LockScreenClockView.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The big lock screen clock: the time in Instrument Serif, its digits a set
//  fraction of the screen's height and centered on it, filled with macOS's
//  clock glass. The lock screen's own text and controls are cut out of it, so
//  they read as written on top.
//

import AppKit
import CoreText
import Defaults
import SwiftUI

@MainActor
final class LockScreenClockModel: ObservableObject {
    @Published var screenSize: CGSize = .zero
    @Published var controls: [LockScreenControl] = []
    /// System Settings → Lock Screen → Show user name and photo.
    @Published var showsPicture = true
}

/// The clock on the real lock screen, ticking each minute.
struct LockScreenClockView: View {
    @ObservedObject var model: LockScreenClockModel
    @Default(.lockScreenClockStyle) private var style
    @Default(.lockScreenClockHeight) private var height

    var body: some View {
        TimelineView(.everyMinute) { context in
            LockScreenClockFace(date: context.date, screenSize: model.screenSize, controls: model.controls,
                                showsPicture: model.showsPicture, style: style, height: height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The clock at one moment, laid out on a screen of `screenSize`, with
/// `controls` cut out of it. Shared by the lock screen and the preview in Settings.
struct LockScreenClockFace: View {
    let date: Date
    let screenSize: CGSize
    let controls: [LockScreenControl]
    let showsPicture: Bool
    let style: LockScreenClockStyle
    let height: Double

    var body: some View {
        let time = Self.timeString(date)
        // As tall as asked, unless that's wider than the screen (10:08 is wider than 11:11).
        let font = ClockFont.sized(digitHeight: screenSize.height * height, fitting: time, in: screenSize.width * 0.92)
        let text = Text(time).font(Font(font.font))
        Group {
            if let glass = GlassTextMaterial.material(style.glassVariant) {
                text.foregroundStyle(glass)
            } else {
                text.foregroundStyle(.regularMaterial)
            }
        }
        .environment(\.colorScheme, style.colorScheme)
        .fixedSize()
        // Center the digits themselves, not the line they sit on.
        .alignmentGuide(VerticalAlignment.center) { d in d[.firstTextBaseline] - font.digitMidY }
        .frame(width: screenSize.width, height: screenSize.height)
        .mask {
            Rectangle()
                .overlay { LockScreenClockCutouts.path(for: controls, showsPicture: showsPicture).fill().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }

    /// The time without AM/PM, in the user's 12- or 24-hour preference.
    static func timeString(_ date: Date) -> String {
        formatter.string(from: date).trimmingCharacters(in: .whitespaces)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        f.amSymbol = ""
        f.pmSymbol = ""
        return f
    }()
}

/// Instrument Serif, bundled under the SIL Open Font License.
private enum ClockFont {
    static let base: CTFont = {
        guard let url = Bundle.main.url(forResource: "InstrumentSerif-Regular", withExtension: "ttf"),
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return CTFontCreateUIFontForLanguage(.system, 100, nil)! }
        return CTFontCreateWithFontDescriptor(descriptor, 100, nil)
    }()

    /// A digit's bounds at size 100.
    static let digitBox: CGRect = {
        var character: UniChar = 0x30   // "0"
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(base, &character, &glyph, 1)
        return CTFontGetBoundingRectsForGlyphs(base, .default, &glyph, nil, 1)
    }()

    /// The font at the size whose digits are `digitHeight` tall, or smaller if
    /// `text` would then be wider than `maxWidth`, and how far above the
    /// baseline the digits' middle is.
    static func sized(digitHeight: CGFloat, fitting text: String, in maxWidth: CGFloat) -> (font: CTFont, digitMidY: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: base]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = min(digitHeight / max(digitBox.height, 1), maxWidth / max(width, 1))
        return (CTFontCreateCopyWithAttributes(base, 100 * scale, nil, nil), digitBox.midY * scale)
    }
}

/// Holes the exact shape of the lock screen's own text and controls, so they
/// sit on the clock with no gap around them. The shapes Accessibility doesn't
/// report were measured on macOS 27's lock screen.
enum LockScreenClockCutouts {
    /// The account picture: a circle centered above the "Touch ID or Enter
    /// Password" line (which stays put when the password field replaces the name).
    static let pictureDiameter: CGFloat = 48
    static let pictureCenterAboveHint: CGFloat = 71.5
    /// The password field's capsule reaches this far left of its text area
    /// and runs to the end of the arrow button inside it.
    static let fieldLeading: CGFloat = 13
    static let fieldHeight: CGFloat = 27.5
    /// Buttons outside the capsule, like "?", are circles this size.
    static let buttonDiameter: CGFloat = 28

    static func path(for controls: [LockScreenControl], showsPicture: Bool) -> Path {
        let path = CGMutablePath()
        let texts = controls.filter { $0.kind == .text }
        for text in texts {
            if let string = text.text { path.addPath(textHole(string, in: text.frame)) }
        }

        var capsules: [CGRect] = []
        for field in controls where field.kind == .field {
            // The arrow button just after the field sits inside its capsule.
            let arrow = controls.filter { $0.kind == .button && abs($0.frame.minX - field.frame.maxX) < 6 && abs($0.frame.midY - field.frame.midY) < 6 }.first
            let right = arrow?.frame.maxX ?? field.frame.maxX
            let capsule = CGRect(x: field.frame.minX - fieldLeading, y: field.frame.midY - fieldHeight / 2,
                                 width: right - field.frame.minX + fieldLeading, height: fieldHeight)
            capsules.append(capsule)
            path.addRoundedRect(in: capsule, cornerWidth: fieldHeight / 2, cornerHeight: fieldHeight / 2)
        }
        for button in controls where button.kind == .button && !capsules.contains(where: { $0.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) }) {
            path.addEllipse(in: CGRect(x: button.frame.midX - buttonDiameter / 2, y: button.frame.midY - buttonDiameter / 2,
                                       width: buttonDiameter, height: buttonDiameter))
        }

        // The hint is the lowest line of text.
        if showsPicture, let hint = texts.map(\.frame).max(by: { $0.minY < $1.minY }) {
            let center = CGPoint(x: hint.midX, y: hint.minY - pictureCenterAboveHint)
            path.addEllipse(in: CGRect(x: center.x - pictureDiameter / 2, y: center.y - pictureDiameter / 2,
                                       width: pictureDiameter, height: pictureDiameter))
        }
        return Path(path)
    }

    /// Shaped like the letters as the lock screen draws them in `bounds`. The
    /// font is a close match, not the lock screen's exact one, so the outline
    /// grows by a point to keep glass off the letters' edges.
    private static func textHole(_ text: String, in bounds: CGRect) -> CGPath {
        let font = NSFont.systemFont(ofSize: max(bounds.height * 0.8, 8), weight: .medium)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<count {
                if let outline = CTFontCreatePathForGlyph(runFont, ids[i], nil) {
                    glyphs.addPath(outline, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
                }
            }
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let scale = bounds.width / max(width, 1)
        // Text is y-up from its baseline; the screen is y-down.
        var transform = CGAffineTransform(translationX: bounds.minX, y: bounds.minY + ascent * scale).scaledBy(x: scale, y: -scale)
        guard let placed = glyphs.copy(using: &transform) else { return CGPath(rect: bounds, transform: nil) }
        return placed.union(placed.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }
}
