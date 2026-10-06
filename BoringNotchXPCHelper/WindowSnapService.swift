//
//  WindowSnapService.swift
//  BoringNotchXPCHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Moves and resizes another app's window for window snapping. The app is
//  sandboxed and can't touch other apps' windows; this helper has
//  Accessibility access.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// The window-server ID behind an Accessibility window. Private, but stable
/// for years and what window managers rely on (Rectangle, Amethyst, yabai).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

private let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

private extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func axValue(_ attribute: String) -> AXValue? {
        guard let value = value(attribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        // The type ID was just checked; a CF type can't be cast conditionally.
        return unsafeBitCast(value, to: AXValue.self)
    }

    var frame: CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(kAXPositionAttribute),
              let extent = axValue(kAXSizeAttribute),
              AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, to value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(kAXPositionAttribute, to: value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(kAXSizeAttribute, to: value)
    }
}

enum WindowSnapService {
    /// Gives window `windowID` of process `pid` the frame `frame`, in the
    /// top-left-origin global coordinates the Accessibility API uses.
    /// Blocking — call off the main queue.
    static func snap(windowID: CGWindowID, pid: pid_t, to frame: CGRect) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        // A hung app shouldn't hold the helper for the default six seconds.
        AXUIElementSetMessagingTimeout(app, 1)
        guard let window = window(withID: windowID, in: app) else {
            NSLog("[boringNotch] window snapping: no window %u in pid %d", windowID, pid)
            return false
        }

        // With enhanced UI on (VoiceOver, other window tools) some apps
        // animate AX resizes, and the move lands before the resize
        // finishes. Off for the change, then back as it was.
        let enhancedUI = app.value(enhancedUserInterfaceAttribute) as? Bool == true
        if enhancedUI { app.set(enhancedUserInterfaceAttribute, to: kCFBooleanFalse) }
        defer { if enhancedUI { app.set(enhancedUserInterfaceAttribute, to: kCFBooleanTrue) } }

        guard apply(frame, to: window) else { return false }

        // The release that ended the drag can still be settling in the
        // app; if it put the window back, place it once more.
        Thread.sleep(forTimeInterval: 0.1)
        if let landed = window.frame,
           abs(landed.minX - frame.minX) > 2 || abs(landed.minY - frame.minY) > 2 {
            apply(frame, to: window)
        }
        return true
    }

    /// Size, position, size: moving to another display, the size the window
    /// arrives with can push it back off the edge, and some apps clamp the
    /// size to the display the window is on when it's set.
    @discardableResult
    private static func apply(_ frame: CGRect, to window: AXUIElement) -> Bool {
        let resizable = window.isSettable(kAXSizeAttribute)
        if resizable { window.setSize(frame.size) }
        let moved = window.setPosition(frame.origin)
        if resizable { window.setSize(frame.size) }
        return moved
    }

    /// The app's window with this window-server ID. Falls back to matching
    /// its current bounds should the private lookup ever stop working.
    private static func window(withID windowID: CGWindowID, in app: AXUIElement) -> AXUIElement? {
        guard let windows = app.value(kAXWindowsAttribute) as? [AXUIElement] else { return nil }

        if let match = windows.first(where: { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == windowID
        }) {
            return match
        }

        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { return nil }
        return windows.first { element in
            guard let frame = element.frame else { return false }
            return abs(frame.minX - bounds.minX) < 1 && abs(frame.minY - bounds.minY) < 1
                && abs(frame.width - bounds.width) < 1 && abs(frame.height - bounds.height) < 1
        }
    }
}
