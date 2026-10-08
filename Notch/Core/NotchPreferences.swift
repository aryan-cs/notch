//
//  NotchPreferences.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Options that shape the notch itself: its height, which displays it
//  appears on, when it hides, and how sneak peeks and the Option key behave.
//

import Defaults
import SwiftUI

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    case preferredDisplay
    case fallbackIfPreferredUnavailable
    case activeDisplay
    case allDisplays

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .preferredDisplay:
            "Use preferred display"
        case .fallbackIfPreferredUnavailable:
            "Automatically switch display if preferred is unavailable"
        case .activeDisplay:
            "Always follow active display"
        case .allDisplays:
            "Show on all displays"
        }
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case inline

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "standard", "Default": self = .standard
        case "inline", "Inline": self = .inline
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .standard:
            return String(localized: "Default", comment: "Sneak Peek style: Default")
        case .inline:
            return String(localized: "Inline", comment: "Sneak Peek style: Inline")
        }
    }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "openSettings", "Open System Settings": self = .openSettings
        case "showOSD", "Show HUD": self = .showOSD
        case "none", "No Action": self = .none
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .openSettings:
            return String(localized: "Open System Settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return String(localized: "Show OSD", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return String(localized: "No action", comment: "Option (⌥) key behavior: No action")
        }
    }
}
