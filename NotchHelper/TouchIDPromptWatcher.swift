//
//  TouchIDPromptWatcher.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Watches for the system's Touch ID prompts so Face Unlock can answer them
//  too. Apps' prompts ("Google Chrome is trying to verify it's you…") come
//  from LocalAuthentication's UI agent, coreautha; administrator prompts
//  come from SecurityAgent. Both can be read and driven through
//  Accessibility.
//
//  Only prompts that offer Touch ID and a password are handled; prompts
//  that only take a fingerprint, like Apple Pay, are left alone. Once the
//  app approves a prompt, `fill` clicks Use Password… if it's there, types
//  the stored password into the prompt's password field, and confirms.
//

import AppKit
import ApplicationServices

/// A Touch ID prompt on screen.
struct TouchIDPrompt {
    let id: String
    let pid: pid_t
    /// The prompt's window, in top-left-origin global coordinates.
    let frame: CGRect
    /// What the prompt says, e.g. "Google Chrome is trying to verify it's you…".
    let reason: String

    var dictionary: [String: String] {
        ["id": id, "reason": reason]
    }
}

/// Its state lives on `queue`.
final class TouchIDPromptWatcher: @unchecked Sendable {
    /// The processes that draw Touch ID prompts, by window owner name.
    private static let agents: Set<String> = ["coreautha", "SecurityAgent"]
    /// How often to look. A prompt shows up at most this late.
    private static let interval: DispatchTimeInterval = .milliseconds(400)
    /// A new window's contents can take a moment to appear; it's given this
    /// long to look like a Touch ID prompt before being ignored.
    private static let settleTime: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "Notch.touchIDPrompts")
    private var timer: DispatchSourceTimer?
    private var onPrompt: ((TouchIDPrompt) -> Void)?
    private var onClose: ((String) -> Void)?
    private var open: [String: TouchIDPrompt] = [:]
    /// Windows seen but not (yet) recognized as prompts, and when.
    private var pending: [String: Date] = [:]
    /// Prompts seen once. They're reported on the next look if they're still
    /// there, which skips the brief windows a prompt leaves as it closes.
    private var candidates: Set<String> = []
    private var ignored: Set<String> = []

    func start(onPrompt: @escaping (TouchIDPrompt) -> Void, onClose: @escaping (String) -> Void) {
        queue.sync {
            self.onPrompt = onPrompt
            self.onClose = onClose
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            Log.helper.notice("Watching for Touch ID prompts")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            open.removeAll()
            pending.removeAll()
            candidates.removeAll()
            ignored.removeAll()
        }
    }

    func isOpen(_ id: String) -> Bool {
        queue.sync { open[id] != nil }
    }

    private func poll() {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var present: Set<String> = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, Self.agents.contains(owner),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            let id = "\(pid)-\(number)"
            present.insert(id)
            guard open[id] == nil, !ignored.contains(id) else { continue }
            // One prompt per agent at a time; more windows from it are parts
            // of the one already showing.
            guard !open.values.contains(where: { $0.pid == pid }) else { continue }

            if let reason = Self.touchIDPromptReason(pid: pid, frame: frame) {
                guard candidates.contains(id) else {
                    candidates.insert(id)
                    continue
                }
                let prompt = TouchIDPrompt(id: id, pid: pid, frame: frame, reason: reason)
                open[id] = prompt
                pending[id] = nil
                candidates.remove(id)
                Log.helper.notice("Touch ID prompt from \(owner, privacy: .public)")
                onPrompt?(prompt)
            } else if let seen = pending[id] {
                if Date().timeIntervalSince(seen) > Self.settleTime {
                    ignored.insert(id)
                    pending[id] = nil
                }
            } else {
                pending[id] = Date()
            }
        }
        for id in open.keys where !present.contains(id) {
            open[id] = nil
            onClose?(id)
        }
        pending = pending.filter { present.contains($0.key) }
        candidates.formIntersection(present)
        ignored.formIntersection(present)
    }

    // MARK: - Reading the prompt

    /// The prompt's text if the window offers Touch ID and a password; nil
    /// for anything else. A Use Password… button is enough: prompts only
    /// show it next to Touch ID. coreautha also labels its fingerprint image
    /// "touchid", which counts alongside a password field; SecurityAgent
    /// labels nothing.
    private static func touchIDPromptReason(pid: pid_t, frame: CGRect) -> String? {
        guard let window = axWindow(pid: pid, frame: frame) else { return nil }
        var hasUsePassword = false
        var hasTouchIDImage = false
        var hasPasswordField = false
        var texts: [String] = []
        walk(window) { element in
            let role = string(element, kAXRoleAttribute)
            let label = (string(element, kAXDescriptionAttribute) ?? "") + (string(element, kAXIdentifierAttribute) ?? "")
            if role == kAXImageRole, label.lowercased().replacingOccurrences(of: " ", with: "").contains("touchid") {
                hasTouchIDImage = true
            }
            if isUsePasswordButton(element) { hasUsePassword = true }
            if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { hasPasswordField = true }
            if role == kAXStaticTextRole, let text = string(element, kAXValueAttribute), !text.isEmpty {
                texts.append(text)
            }
        }
        guard hasUsePassword || (hasTouchIDImage && hasPasswordField) else { return nil }
        return texts.joined(separator: " ")
    }

    // MARK: - Filling it in

    /// Clicks Use Password… if needed, types `password` into the prompt's
    /// password field and confirms. Keystrokes are only sent while the
    /// prompt itself holds secure keyboard input, which macOS gives to the
    /// app whose password field has the keyboard, so they can't land
    /// anywhere else. Runs off the main thread; it waits for the prompt.
    static func fill(_ prompt: TouchIDPrompt, password: String) -> Bool {
        guard let window = axWindow(pid: prompt.pid, frame: prompt.frame) else { return false }
        if let usePassword = first(in: window, where: isUsePasswordButton) {
            AXUIElementPerformAction(usePassword, kAXPressAction as CFString)
        }
        var field: AXUIElement?
        for _ in 0..<30 {
            field = first(in: window) { string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole }
            if field != nil { break }
            usleep(50_000)
        }
        guard let field else { return false }
        // An administrator prompt also asks for a user name; it has to be
        // filled in already, since guessing it would be wrong.
        if let nameField = first(in: window, where: {
            string($0, kAXRoleAttribute) == kAXTextFieldRole && string($0, kAXSubroleAttribute) != kAXSecureTextFieldSubrole
        }), (string(nameField, kAXValueAttribute) ?? "").isEmpty {
            return false
        }

        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let promptHasKeyboard = { secureInputOwner() == prompt.pid }
        for _ in 0..<20 where !promptHasKeyboard() {
            usleep(50_000)
        }
        if promptHasKeyboard() {
            return Keystrokes.replaceFieldText(with: password, while: promptHasKeyboard)
        }
        // The keyboard never reached the prompt, so set the field directly
        // and press its confirm button instead of typing.
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString) == .success,
              let confirm = confirmButton(in: window)
        else { return false }
        return AXUIElementPerformAction(confirm, kAXPressAction as CFString) == .success
    }

    private static func secureInputOwner() -> pid_t? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }

    /// The window's default button, or its only button that isn't a way out.
    private static func confirmButton(in window: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        let declining = ["cancel", "don't allow", "don’t allow", "deny"]
        var candidates: [AXUIElement] = []
        walk(window) { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole, !isUsePasswordButton(element) else { return }
            let label = (string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? "").lowercased()
            if !declining.contains(label) { candidates.append(element) }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Accessibility helpers

    private static func isUsePasswordButton(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute) == kAXButtonRole else { return false }
        let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
        return label.hasPrefix("Use Password")
    }

    /// The agent's window at `frame`, or its only window.
    private static func axWindow(pid: pid_t, frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty
        else { return nil }
        if windows.count == 1 { return windows[0] }
        return windows.first { window in
            guard let position = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute) else { return false }
            return abs(position.x - frame.minX) < 3 && abs(position.y - frame.minY) < 3
                && abs(size.width - frame.width) < 3 && abs(size.height - frame.height) < 3
        }
    }

    private static func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
        guard depth < 12 else { return }
        visit(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, visit) }
    }

    private static func first(in element: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(element) { if found == nil, matches($0) { found = $0 } }
        return found
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point)
        else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &size)
        else { return nil }
        return size
    }
}
