//
//  ScreenLock.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import CoreGraphics

enum ScreenLock {
    /// Whether the login window is covering the screen right now. Reads an
    /// undocumented key of the session dictionary, which macOS has kept
    /// stable for years.
    static var isLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
