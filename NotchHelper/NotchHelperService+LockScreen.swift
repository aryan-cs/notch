//
//  NotchHelperService+LockScreen.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  For the big lock screen clock: what loginwindow is showing (so the clock
//  can leave room for it), and whether macOS's own clock is on. Read-only;
//  the controls are only read while the screen is locked.
//

import AppKit
import ApplicationServices
import Foundation

extension NotchHelperService {
    @objc func lockScreenControls(with reply: @escaping (Data?) -> Void) {
        guard AXIsProcessTrusted() else {
            reply(nil)
            return
        }
        guard Self.isScreenLocked() else {
            reply(try? JSONEncoder().encode([LockScreenControl]()))
            return
        }
        reply(try? JSONEncoder().encode(LockScreenReader.controls()))
    }

    @objc func lockScreenWallpaper(maxWidth: Int, with reply: @escaping (Data?) -> Void) {
        guard let screen = NSScreen.screens.first,
              let image = Self.wallpaperFile(for: screen) ?? Self.renderedWallpaper(for: screen), image.size.width > 0
        else {
            reply(nil)
            return
        }
        let scale = min(1, CGFloat(maxWidth) / image.size.width)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            reply(nil)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        reply(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
    }

    private static func wallpaperFile(for screen: NSScreen) -> NSImage? {
        NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:))
    }

    /// The wallpaper agent keeps what it draws, at the display's pixel size,
    /// which is still there when the picture's file has been moved or deleted.
    private static func renderedWallpaper(for screen: NSScreen) -> NSImage? {
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches")
        let pixels = "-\(Int(screen.frame.width * screen.backingScaleFactor))-\(Int(screen.frame.height * screen.backingScaleFactor))-"
        let renders = (FileManager.default.subpaths(atPath: caches.path) ?? [])
            .filter { $0.contains(pixels) }
            .map { caches.appendingPathComponent($0) }
        let newest = renders.max { modified($0) < modified($1) }
        return newest.flatMap(NSImage.init(contentsOf:))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @objc func lockScreenShowsUserNameAndPhoto(with reply: @escaping (Bool) -> Void) {
        let prefs = NSDictionary(contentsOfFile: Self.loginWindowPrefs)
        reply((prefs?["HideUserAvatarAndName"] as? NSNumber)?.boolValue != true)
    }

    /// System Settings → Lock Screen → Show user name and photo. It's a
    /// system-wide setting, so macOS asks for an administrator password.
    @objc func setLockScreenShowsUserNameAndPhoto(_ shown: Bool, with reply: @escaping (_ succeeded: Bool, _ message: String?) -> Void) {
        let command = "/usr/bin/defaults write \(Self.loginWindowPrefs) HideUserAvatarAndName -bool \(shown ? "NO" : "YES")"
        let prompt = shown ? "Notch wants to show your name and photo on the lock screen."
                           : "Notch wants to hide your name and photo on the lock screen."
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges")?
            .executeAndReturnError(&error)
        guard let error else {
            reply(true, nil)
            return
        }
        // -128 is the user clicking Cancel.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            reply(false, nil)
        } else {
            reply(false, error[NSAppleScript.errorMessage] as? String ?? "That didn't work.")
        }
    }

    private static let loginWindowPrefs = "/Library/Preferences/com.apple.loginwindow.plist"

    @objc func isSystemLockScreenClockShown(with reply: @escaping (Bool) -> Void) {
        // Set to 0 by Show large clock → Never; missing until it's changed.
        let prefs = NSDictionary(contentsOfFile: Self.loginWindowPrefs)
        reply((prefs?["UsesLargeDateTime"] as? NSNumber)?.intValue != 0)
    }
}

/// Walks loginwindow's Accessibility tree.
private enum LockScreenReader {
    static func controls() -> [LockScreenControl] {
        let screenArea = NSScreen.screens.first.map { $0.frame.width * $0.frame.height } ?? 1
        var controls: [LockScreenControl] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.apple.loginwindow" {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            for window in value(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                walk(window, depth: 0) { element in
                    guard let frame = frame(element), frame.width > 1, frame.height > 1,
                          // The menu bar items; and the whole-screen user list.
                          frame.minY > 40, frame.width * frame.height < screenArea * 0.05,
                          let role = value(element, kAXRoleAttribute) as? String
                    else { return }
                    switch role {
                    case kAXStaticTextRole, kAXTextAreaRole:
                        guard let text = value(element, kAXValueAttribute) as? String, !text.isEmpty else { return }
                        controls.append(LockScreenControl(kind: .text, frame: characterBounds(element, text) ?? frame, text: text))
                    case kAXTextFieldRole:
                        controls.append(LockScreenControl(kind: .field, frame: frame))
                    case kAXButtonRole:
                        controls.append(LockScreenControl(kind: .button, frame: frame))
                    default:
                        break
                    }
                }
            }
        }
        return controls
    }

    private static func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Void) {
        guard depth < 14 else { return }
        visit(element)
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, depth: depth + 1, visit)
        }
    }

    /// Where the characters themselves are; a text area is wider than its text.
    private static func characterBounds(_ element: AXUIElement, _ text: String) -> CGRect? {
        var range = CFRange(location: 0, length: (text as NSString).length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &bounds), bounds.width > 1 else { return nil }
        return bounds
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
