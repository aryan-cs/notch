//
//  SudoIntegration.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Turns Face Unlock for sudo on and off by running sudo-integration.sh as
//  root, after the user approves the administrator prompt, and reports
//  whether it's on.
//
//  Turning it on records this helper's code requirement, which the PAM
//  module checks before trusting an answer. A different build of Notch
//  (an update, or a rebuild with another signature) won't match, so the
//  status becomes `.outdated` and sudo asks for a password until the user
//  turns the feature on again.
//

import AppKit
import Foundation
import Security

enum SudoIntegration {
    static let installedModule = URL(fileURLWithPath: "/usr/local/lib/pam/pam_notch.so.2")
    static let installedRequirement = URL(fileURLWithPath: "/usr/local/etc/notch-sudo.requirement")
    static let config = URL(fileURLWithPath: "/etc/pam.d/sudo_local")

    /// Notch.app, three folders up from Contents/XPCServices/NotchHelper.xpc.
    private static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var bundledModule: URL {
        appURL.appendingPathComponent("Contents/Library/PAM/pam_notch.so")
    }

    static func status() -> SudoIntegrationStatus {
        guard let config = try? String(contentsOf: config, encoding: .utf8),
              config.contains("pam_notch.so")
        else { return .off }
        // sudo only trusts the helper it recorded when the feature was turned on.
        guard FileManager.default.fileExists(atPath: installedModule.path),
              let requirement = try? String(contentsOf: installedRequirement, encoding: .utf8),
              requirement.trimmingCharacters(in: .whitespacesAndNewlines) == ownRequirement()
        else { return .outdated }
        // Compared by code hash, which only changes with the code, not with
        // each signature.
        guard let installed = codeHash(of: installedModule), installed == codeHash(of: bundledModule) else {
            return .updateAvailable
        }
        return .on
    }

    /// Runs the install or uninstall script with administrator rights. Must
    /// be called on the main thread, which NSAppleScript requires.
    static func setEnabled(_ enabled: Bool) -> (succeeded: Bool, message: String?) {
        guard let script = Bundle.main.url(forResource: "sudo-integration", withExtension: "sh") else {
            return (false, "Notch is missing a file it needs. Try reinstalling it.")
        }
        var arguments = [script.path]
        if enabled {
            guard FileManager.default.fileExists(atPath: bundledModule.path) else {
                return (false, "Notch is missing a file it needs. Try reinstalling it.")
            }
            guard let requirement = ownRequirement() else {
                return (false, "Notch couldn't read its own code signature.")
            }
            let requirementFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-sudo-\(UUID().uuidString).requirement")
            do {
                try requirement.write(to: requirementFile, atomically: true, encoding: .utf8)
            } catch {
                return (false, "Notch couldn't prepare the change.")
            }
            defer { try? FileManager.default.removeItem(at: requirementFile) }
            arguments += ["install", bundledModule.path, requirementFile.path]
            return run(arguments, prompt: "Notch wants to let Face Unlock approve sudo.")
        } else {
            arguments.append("uninstall")
            return run(arguments, prompt: "Notch wants to stop Face Unlock from approving sudo.")
        }
    }

    private static func run(_ arguments: [String], prompt: String) -> (succeeded: Bool, message: String?) {
        let command = "/bin/sh " + arguments.map(shellQuoted).joined(separator: " ")
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else {
            Log.helper.notice("sudo integration changed: \(arguments.dropFirst().first ?? "", privacy: .public)")
            return (true, nil)
        }
        // -128 is the user clicking Cancel.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return (false, nil) }
        let message = error[NSAppleScript.errorMessage] as? String
        Log.helper.error("sudo integration failed: \(message ?? "unknown error", privacy: .public)")
        return (false, message ?? "That didn't work.")
    }

    private static func codeHash(of url: URL) -> Data? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }

    /// This helper's designated requirement, as text.
    static func ownRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        return text as String
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
