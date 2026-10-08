//
//  NotchHelperService+Accessibility.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Accessibility permission, and the work that needs it: pressing menu bar
//  items and Spotify menu commands, and moving windows for window snapping.
//

import AppKit
import ApplicationServices

extension NotchHelperService {
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        guard promptIfNeeded else {
            reply(false)
            return
        }

        requestAccessibilityAuthorization()

        let deadline = DispatchTime.now() + .seconds(15)
        func waitForAuthorization() {
            if AXIsProcessTrusted() {
                reply(true)
            } else if DispatchTime.now() >= deadline {
                reply(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    waitForAuthorization()
                }
            }
        }
        waitForAuthorization()
    }

    /// Opens one of macOS's own menu bar menus (battery, Wi-Fi, …) by pressing
    /// its menu bar item, so the app can show the real menu instead of a copy.
    /// The menu appears under that item, where macOS anchors it.
    ///
    /// Only Apple's `com.apple.menuextra.*` items can be pressed. Those live in
    /// MenuBarAgent on macOS 26 and later, and in ControlCenter before that.
    /// Replies false when the item isn't in the menu bar (the user hid it) or
    /// Accessibility isn't granted.
    @objc func openSystemMenuExtra(_ identifier: String, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), identifier.hasPrefix("com.apple.menuextra.") else {
            reply(false)
            return
        }
        for bundleID in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var extras: CFTypeRef?
                let root = AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extras) == .success
                    ? extras as! AXUIElement
                    : appElement
                if let item = Self.element(withIdentifier: identifier, in: root),
                   AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                    reply(true)
                    return
                }
            }
        }
        reply(false)
    }

    /// Presses Spotify's Playback ▸ Repeat or Shuffle menu command, the same
    /// as its own buttons. Repeat cycles off → all → one, which Spotify's
    /// AppleScript (repeat on/off only) can't do. Only those two items, only
    /// in Spotify; works with Spotify in the background.
    @objc func pressSpotifyPlaybackItem(_ item: String, with reply: @escaping (Bool) -> Void) {
        // Title → its key equivalent (⌘R, ⌘S), for a Spotify running in
        // another language.
        let keyEquivalents = ["Repeat": "R", "Shuffle": "S"]
        guard AXIsProcessTrusted(),
              let keyEquivalent = keyEquivalents[item],
              let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first,
              let menuBar = Self.axElement(AXUIElementCreateApplication(spotify.processIdentifier), kAXMenuBarAttribute)
        else {
            reply(false)
            return
        }
        let menus = Self.axChildren(menuBar).compactMap { Self.axChildren($0).first }
        let entries = menus.flatMap { Self.axChildren($0) }
        let byTitle = entries.first { Self.axString($0, kAXTitleAttribute) == item }
        // Otherwise the ⌘-key item in the menu that has both ⌘R and ⌘S.
        let byKey: AXUIElement? = byTitle != nil ? nil : menus.lazy.compactMap { menu -> AXUIElement? in
            let items = Self.axChildren(menu)
            let commandKeys = items.filter { Self.axNumber($0, kAXMenuItemCmdModifiersAttribute) == 0 }
            let keys = Set(commandKeys.compactMap { Self.axString($0, kAXMenuItemCmdCharAttribute)?.uppercased() })
            guard keys.isSuperset(of: Set(keyEquivalents.values)) else { return nil }
            return commandKeys.first { Self.axString($0, kAXMenuItemCmdCharAttribute)?.uppercased() == keyEquivalent }
        }.first
        guard let target = byTitle ?? byKey else {
            reply(false)
            return
        }
        reply(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success)
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axNumber(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func element(withIdentifier identifier: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value) == .success,
           value as? String == identifier {
            return element
        }
        guard depth < 4,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }
        for child in children {
            if let match = self.element(withIdentifier: identifier, in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    /// Window snapping: moves and resizes another app's window to `frame`
    /// (see WindowSnapService). False if the window couldn't be found or
    /// moved, or Accessibility isn't granted.
    @objc func snapWindow(_ windowID: UInt32, ownerPID: Int32, to frame: CGRect, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            reply(WindowSnapService.snap(windowID: windowID, pid: ownerPID, to: frame))
        }
    }
}
