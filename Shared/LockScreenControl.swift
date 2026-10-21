//
//  LockScreenControl.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Something the lock screen shows that the big clock must not cover: a line
//  of text, the password field, a button. NotchHelper reads them from
//  loginwindow through Accessibility and sends them to the app as JSON.
//

import CoreGraphics
import Foundation

struct LockScreenControl: Codable, Equatable {
    enum Kind: String, Codable {
        /// A line of text; `frame` is the exact bounds of its characters.
        case text
        /// The password field (just its text area, not the capsule around it).
        case field
        /// A button, like the password field's arrow or the "?".
        case button
    }

    var kind: Kind
    /// In top-left-origin screen coordinates.
    var frame: CGRect
    var text: String?
}
