//
//  OSDControlSource.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Where volume and brightness changes come from (Settings → OSD).
//

import Defaults
import Foundation

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .builtin:
            return String(localized: "Built-in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}
