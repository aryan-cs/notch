//
//  WebAccessibility.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Chromium browsers only build their pages' Accessibility trees while
//  something asks for them (AXManualAccessibility); Safari always does. The
//  sign-in helpers each hold that request while they read a browser's pages
//  and share it, so one finishing doesn't take the page away from the other.
//

import AppKit
import ApplicationServices

enum WebAccessibility {
    private static let lock = NSLock()
    private static var holds: [pid_t: Int] = [:]

    /// Asks `app` for its pages. True if it needed asking; release it later.
    static func hold(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != "com.apple.Safari" else { return false }
        let pid = app.processIdentifier
        lock.lock()
        defer { lock.unlock() }
        holds[pid, default: 0] += 1
        if holds[pid] == 1 { set(pid, true) }
        return true
    }

    static func release(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = holds[pid] else { return }
        if count > 1 {
            holds[pid] = count - 1
            return
        }
        holds[pid] = nil
        set(pid, false)
    }

    private static func set(_ pid: pid_t, _ on: Bool) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     on ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
