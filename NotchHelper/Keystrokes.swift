//
//  Keystrokes.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Types text into whatever field has the keyboard, for Face Unlock: the
//  lock screen's password field, and the password field of a Touch ID
//  prompt. Callers pass a check that's repeated before every keystroke, so
//  typing stops the moment the keyboard is somewhere it shouldn't be.
//

import CoreGraphics
import Foundation

enum Keystrokes {
    /// Replaces the focused field's text with `text`, then presses Return.
    /// False if `stillSafe` turned false along the way.
    static func replaceFieldText(with text: String, thenReturn: Bool = true, while stillSafe: () -> Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState), stillSafe() else { return false }

        // Clear anything already there: Command-A, then Delete.
        press(source, virtualKey: 0x00, flags: .maskCommand)
        press(source, virtualKey: 0x33)

        for character in text {
            guard stillSafe() else { return false }
            type(source, String(character))
        }
        guard stillSafe() else { return false }
        if thenReturn {
            press(source, virtualKey: 0x24)
        }
        return true
    }

    private static func type(_ source: CGEventSource, _ string: String) {
        var utf16 = Array(string.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }

    private static func press(_ source: CGEventSource, virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }
}
