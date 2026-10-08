//
//  FocusShortcut.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Shortcuts the presence guard runs to switch Focus: macOS has no API
//  for setting it. The user makes both, each with one Set Focus action. The
//  XPC helper only ever runs these names.
//

import Foundation

enum FocusShortcut: String, CaseIterable, Sendable {
    case on = "Notch Focus On"
    case off = "Notch Focus Off"
}
