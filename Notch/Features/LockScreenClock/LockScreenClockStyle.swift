//
//  LockScreenClockStyle.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The glass the big lock screen clock is made of. Dark and Light are the
//  glass macOS uses for its own lock screen clock; the others are macOS glass
//  made for other things.
//

import Defaults
import SwiftUI

enum LockScreenClockStyle: String, CaseIterable, Codable, Defaults.Serializable {
    case dark, light, monogram, controlCenter

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .monogram: return "Monogram"
        case .controlCenter: return "Control Center"
        }
    }

    /// The `Material._GlassVariant` it's drawn with (see GlassTextMaterial).
    var glassVariant: String {
        switch self {
        case .dark, .light: return "text"
        case .monogram: return "monogram"
        case .controlCenter: return "controlCenter"
        }
    }

    /// The clock glass is pale in a dark appearance and smoky in a light one.
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}
