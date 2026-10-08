//
//  Color+AccentColor.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI
import Defaults

/// Decodes the user's custom accent color, if custom accents are enabled.
private var customAccentNSColor: NSColor? {
    guard Defaults[.useCustomAccentColor],
          let colorData = Defaults[.customAccentColorData],
          let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData)
    else { return nil }
    return nsColor
}

/// True when the system accent is Multicolor: macOS then stores no
/// `AppleAccentColor`, leaving each app to pick its own.
var isSystemAccentMulticolor: Bool {
    UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
}

/// Notch's own pick under Multicolor: the color of what's playing (the same
/// brightened album-art color as the progress slider), or plain white when
/// nothing is — black in a light-mode Settings window, where white would
/// vanish. Nil when a specific system accent is set.
private var multicolorAccentNSColor: NSColor? {
    guard isSystemAccentMulticolor else { return nil }
    let plain = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? .black : .white
    }
    // Views read this on the main thread; anything else gets the plain color.
    guard Thread.isMainThread else { return plain }
    return MainActor.assumeIsolated {
        let music = MusicManager.shared
        guard !music.isPlayerIdle else { return plain }
        return NSColor(Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.8))
    }
}

extension Color {
    static var effectiveAccent: Color {
        if let nsColor = customAccentNSColor ?? multicolorAccentNSColor {
            return Color(nsColor: nsColor)
        }
        return .accentColor
    }

    /// Returns a darker version of the accent color suitable for backgrounds
    static var effectiveAccentBackground: Color {
        if let nsColor = customAccentNSColor {
            return Color(nsColor: nsColor.withSystemEffect(.disabled))
        }
        return Color.effectiveAccent.opacity(0.25)
    }
}

extension NSColor {
    static var effectiveAccent: NSColor {
        customAccentNSColor ?? multicolorAccentNSColor ?? NSColor.controlAccentColor
    }

    /// Returns a darker version of the accent color as NSColor suitable for backgrounds
    static var effectiveAccentBackground: NSColor {
        if let nsColor = customAccentNSColor {
            return nsColor.withSystemEffect(.disabled)
        }
        return NSColor.effectiveAccent.withAlphaComponent(0.25)
    }
}
