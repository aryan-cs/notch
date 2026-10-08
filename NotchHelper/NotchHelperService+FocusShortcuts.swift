//
//  NotchHelperService+FocusShortcuts.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Alert mode turns Focus on and off by running the user's Shortcuts.
//

import Foundation

extension NotchHelperService {
    /// Presence guard: turns Focus on or off through the user's shortcut
    /// (see ShortcutsService). False for any other name, or if it failed.
    @objc func runFocusShortcut(_ name: String, with reply: @escaping (Bool) -> Void) {
        guard let shortcut = FocusShortcut(rawValue: name) else {
            reply(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            reply(ShortcutsService.run(shortcut))
        }
    }

    @objc func installedFocusShortcuts(with reply: @escaping ([String]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(ShortcutsService.installed())
        }
    }
}
