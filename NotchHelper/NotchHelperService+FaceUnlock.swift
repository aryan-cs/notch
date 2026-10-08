//
//  NotchHelperService+FaceUnlock.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock's stored login password and the keystrokes that type it at
//  the lock screen.
//

import AppKit
import CryptoKit
import OpenDirectory
import os

extension NotchHelperService {
    // MARK: - Face Unlock: stored password + lock-screen keystrokes

    // Stored as an obfuscated 0600 file written by this (non-sandboxed) helper,
    // not the keychain: an on-demand, ad-hoc-signed XPC service can't silently
    // write the login keychain (SecItemAdd → errSecInteractionNotAllowed, -25308),
    // and a self-ACL keychain item would break on every rebuild and on keychain
    // auto-lock. A file is the same practical security as the plain login keychain
    // for this threat model — any code running as the user can read either while
    // you're logged in — and it survives rebuilds and reads reliably while locked.
    private var unlockSecretURL: URL {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/theboringteam.boringnotch")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return URL(fileURLWithPath: dir).appendingPathComponent("faceunlock.secret")
    }

    /// Obfuscation only (the key is embedded) — keeps the password out of literal
    /// plaintext on disk and in backups. It is NOT protection against code that
    /// already runs as you; see the storage note above.
    private static func unlockObfuscationKey() -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("theboringteam.boringnotch.faceunlock.v1".utf8)))
    }

    /// Shares the app's Face Unlock log category. Never logs the password
    /// itself, only lengths and error codes.
    private static let log = Logger(subsystem: "theboringteam.boringnotch", category: "faceUnlock")

    @objc func storeUnlockPassword(_ password: String, with reply: @escaping (_ verified: Bool, _ saved: Bool) -> Void) {
        Self.log.notice("Checking a new password (\(password.count) characters)")
        // Never store a wrong password — typing it at the lock screen would trip
        // failed-attempt lockout delays. Verify against the account first.
        guard !password.isEmpty else {
            Self.log.notice("Refused an empty password")
            reply(false, false); return
        }
        guard verifyLoginPassword(password) else { reply(false, false); return }
        let saved = saveUnlockPassword(password)
        Self.log.notice("Password verified, saved: \(saved)")
        reply(true, saved)
    }

    @objc func hasUnlockPassword(with reply: @escaping (Bool) -> Void) {
        reply(loadUnlockPassword() != nil)
    }

    @objc func clearUnlockPassword() {
        try? FileManager.default.removeItem(at: unlockSecretURL)
    }

    @objc func unlockScreenWithStoredPassword(with reply: @escaping (Bool) -> Void) {
        guard let password = loadUnlockPassword() else {
            Self.log.notice("No stored password")
            reply(false); return
        }
        guard AXIsProcessTrusted() else {
            Self.log.error("Accessibility isn't granted, so keystrokes can't be posted")
            reply(false); return
        }
        // Only ever type into the actual lock screen, never a focused app field.
        guard Self.isScreenLocked() else {
            Self.log.error("The screen isn't locked; refusing to type")
            reply(false); return
        }
        reply(typePasswordAtLockScreen(password))
    }

    // MARK: Secret storage (obfuscated 0600 file — readable while the screen is locked)

    private func saveUnlockPassword(_ password: String) -> Bool {
        do {
            let sealed = try AES.GCM.seal(Data(password.utf8), using: Self.unlockObfuscationKey())
            guard let combined = sealed.combined else { return false }
            try combined.write(to: unlockSecretURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unlockSecretURL.path)
            return true
        } catch {
            Self.log.error("Couldn't save the password: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func loadUnlockPassword() -> String? {
        guard let data = try? Data(contentsOf: unlockSecretURL),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: Self.unlockObfuscationKey()) else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    // MARK: Password verification (OpenDirectory — no unlock, just a check)

    private func verifyLoginPassword(_ password: String) -> Bool {
        let user = NSUserName()
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch let error as NSError {
            Self.log.notice("Password check failed: \(error.domain, privacy: .public) \(error.code)")
            return false
        }
    }

    // MARK: Lock state + keystroke injection

    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }
    /// Clears the field, types the password, presses Return. Re-checks the lock
    /// state before every keystroke and aborts if it changes, so the password
    /// can never land in a window that stole focus mid-type.
    private func typePasswordAtLockScreen(_ password: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        // Clear any pre-filled text: Cmd+A, then Delete.
        postKey(source, virtualKey: 0x00, flags: .maskCommand)   // A
        postKey(source, virtualKey: 0x33)                        // Delete

        for character in password {
            guard Self.isScreenLocked() else { return false }
            postUnicode(source, String(character))
        }
        guard Self.isScreenLocked() else { return false }
        postKey(source, virtualKey: 0x24)                        // Return
        return true
    }

    private func postUnicode(_ source: CGEventSource, _ string: String) {
        var utf16 = Array(string.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }

    private func postKey(_ source: CGEventSource, virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }
}
