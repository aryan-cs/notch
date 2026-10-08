//
//  NotchHelperProtocol.swift
//  Notch
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

@objc protocol NotchHelperLunarListener {
    func lunarEventDidUpdate(_ event: LunarBrightnessUpdate)
    func lunarStreamDidStop(_ reason: String?)
}

@objc(LunarBrightnessUpdate)
final class LunarBrightnessUpdate: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let brightness: Double
    let display: Int

    init(brightness: Double, display: Int) {
        self.brightness = brightness
        self.display = display
        super.init()
    }

    required init?(coder: NSCoder) {
        brightness = coder.decodeDouble(forKey: "brightness")
        display = coder.decodeInteger(forKey: "display")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(brightness, forKey: "brightness")
        coder.encode(display, forKey: "display")
    }
}

@objc protocol NotchHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void)
    func isLunarAvailable(with reply: @escaping (Bool) -> Void)
    func startLunarEventStream(with reply: @escaping (Bool) -> Void)
    func stopLunarEventStream()
    func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void)
    func startNotificationWatching(with reply: @escaping (Bool) -> Void)
    func stopNotificationWatching()
    func setNotificationFilter(_ bundleIDs: [String], allApps: Bool)
    func openSystemMenuExtra(_ identifier: String, with reply: @escaping (Bool) -> Void)
    func pressSpotifyPlaybackItem(_ item: String, with reply: @escaping (Bool) -> Void)
    func fetchAppleDevices(with reply: @escaping (Data?) -> Void)
    /// `frame` is in top-left-origin global coordinates, like the Accessibility API's.
    func snapWindow(_ windowID: UInt32, ownerPID: Int32, to frame: CGRect, with reply: @escaping (Bool) -> Void)
    /// Runs one of the presence guard's Focus shortcuts; other names are refused.
    func runFocusShortcut(_ name: String, with reply: @escaping (Bool) -> Void)
    /// Which FocusShortcut names exist in Shortcuts. Nil if they couldn't be listed.
    func installedFocusShortcuts(with reply: @escaping ([String]?) -> Void)

    // MARK: Face Unlock (stored login password + lock-screen keystrokes)

    /// Verifies the password against the local account (OpenDirectory) and, only
    /// if correct, stores it. `verified` is false for a wrong password; `saved` is
    /// false when it was correct but couldn't be stored. Nothing is kept on failure.
    func storeUnlockPassword(_ password: String, with reply: @escaping (_ verified: Bool, _ saved: Bool) -> Void)
    /// Whether a password is currently stored.
    func hasUnlockPassword(with reply: @escaping (Bool) -> Void)
    /// Removes the stored password.
    func clearUnlockPassword()
    /// Types the stored password + Return at the lock screen. Refuses unless the
    /// screen is actually locked (re-checked before each keystroke) and
    /// Accessibility is granted. `false` means no password, not locked, not
    /// trusted, or aborted.
    func unlockScreenWithStoredPassword(with reply: @escaping (Bool) -> Void)
}

@objc protocol NotchHelperNotificationDelegate {
    func notificationDidAppear(_ payload: [String: String])
}

@objc protocol NotchHelperCallbacks: NotchHelperLunarListener, NotchHelperNotificationDelegate {}
