//
//  KeyboardShortcuts+Names.swift
//  Notch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleSneakPeek = Self("toggleSneakPeek", initial: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", initial: .init(.i, modifiers: [.command, .shift]))
    // No default: every obvious combo (⇧⌘V included) already means something in some app.
    static let openClipboardHistory = Self("openClipboardHistory")
}
