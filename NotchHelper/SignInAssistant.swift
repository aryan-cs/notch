//
//  SignInAssistant.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  After Face Unlock fills a browser's Touch ID prompt (the browser asking
//  before it fills a saved password), this presses the buttons you'd press
//  next on Microsoft and Google sign-in pages: Sign in once the password is
//  filled, and Microsoft's "you'll be redirected" Continue. It reads the
//  page through Accessibility and only acts for a short while after the
//  face check, in that browser's front window, on those sites.
//
//  It never presses anything that decides something for you: stay signed in,
//  letting an app use your account, or anything on Duo.
//

import AppKit
import ApplicationServices

final class SignInAssistant: @unchecked Sendable {
    static let shared = SignInAssistant()

    /// Browsers whose sign-in pages it helps with, by bundle identifier.
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.apple.Safari",
    ]

    /// How long after the face check it keeps looking.
    private static let window: TimeInterval = 45
    private static let interval: DispatchTimeInterval = .milliseconds(400)
    /// A sign-in takes a few steps, not dozens.
    private static let maxPresses = 4

    private let queue = DispatchQueue(label: "Notch.signInAssistant")
    private var timer: DispatchSourceTimer?
    private var pid: pid_t = 0
    private var deadline = Date.distantPast
    private var pressed: Set<String> = []
    private var presses = 0
    private var enabledAccessibility = false

    var isEnabled = false

    /// Starts helping the browser behind `prompt`, if it is one. `reason` is
    /// the prompt's text ("Google Chrome is trying to verify it's you…").
    func start(afterPromptWith reason: String) {
        guard isEnabled else {
            Log.helper.notice("Sign-in help is off")
            return
        }
        // Once the prompt has gone and the browser is in front again.
        queue.asyncAfter(deadline: .now() + .milliseconds(800)) { [self] in
            guard let app = Self.browser(named: reason) else {
                Log.helper.notice("Sign-in help: the prompt wasn't from a browser")
                return
            }
            stopTimer()
            pid = app.processIdentifier
            deadline = Date().addingTimeInterval(Self.window)
            pressed = []
            presses = 0
            enabledAccessibility = Self.enableWebAccessibility(app)
            Log.helper.notice("Sign-in help on for \(app.bundleIdentifier ?? "?", privacy: .public)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(300), repeating: Self.interval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    /// The browser named in the prompt, or else the frontmost app if it's a browser.
    private static func browser(named reason: String) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { browsers.contains($0.bundleIdentifier ?? "") }
        if let named = running.first(where: { app in app.localizedName.map { reason.contains($0) } ?? false }) {
            return named
        }
        return running.first { $0.processIdentifier == frontmostPID() }
    }

    /// The app in front, from Accessibility: NSWorkspace's frontmostApplication
    /// goes stale in a service like this one, which doesn't run AppKit's event loop.
    static func frontmostPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func finish(_ why: String) {
        stopTimer()
        if enabledAccessibility, let app = NSRunningApplication(processIdentifier: pid) {
            Self.setWebAccessibility(app, false)
        }
        enabledAccessibility = false
        Log.helper.notice("Sign-in help off: \(why, privacy: .public)")
    }

    // MARK: - Looking at the page

    private func poll() {
        guard Date() < deadline else { return finish("time's up") }
        guard presses < Self.maxPresses else { return finish("done") }
        // Only while you're looking at that browser.
        guard Self.frontmostPID() == pid,
              let page = Page.read(pid: pid),
              let rule = SignInRule.for(host: page.host),
              let button = rule.buttonToPress(on: page)
        else { return }
        let key = "\(page.url)#\(button.key)"
        guard !pressed.contains(key) else { return }
        pressed.insert(key)
        let pressedIt = press(button)
        presses += 1
        Log.helper.notice("Sign-in help pressed \(button.key, privacy: .public) on \(page.host, privacy: .public): \(pressedIt)")
    }

    /// Safari's buttons take Accessibility's press; Chrome's web buttons
    /// don't, so the button gets the keyboard focus and Return goes to that
    /// browser alone, only once the button really has the focus.
    private func press(_ button: Page.Button) -> Bool {
        var names: CFArray?
        if AXUIElementCopyActionNames(button.element, &names) == .success,
           (names as? [String])?.contains(kAXPressAction) == true {
            return AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
        }
        guard AXUIElementSetAttributeValue(button.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        usleep(150_000)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button.element, kAXFocusedAttribute as CFString, &focused) == .success,
              (focused as? Bool) == true, Self.frontmostPID() == pid
        else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: down)?.postToPid(pid)   // Return
        }
        return true
    }

    /// Chromium browsers only build their pages' Accessibility trees when
    /// something asks; Safari always does.
    private static func enableWebAccessibility(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != "com.apple.Safari" else { return false }
        return setWebAccessibility(app, true)
    }

    @discardableResult
    private static func setWebAccessibility(_ app: NSRunningApplication, _ on: Bool) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
}

/// What's on the sign-in page, as far as these rules care.
struct Page {
    struct Button {
        let element: AXUIElement
        let title: String
        let domID: String?
        var key: String { domID ?? title }
    }

    let url: String
    let host: String
    var buttons: [Button] = []
    /// Character counts of the password fields.
    var passwordLengths: [Int] = []
    /// Other text fields and checkboxes: anything you'd fill in or decide.
    var otherInputs = 0
    var text = ""

    /// The front window's page, if it has one.
    static func read(pid: pid_t) -> Page? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = value(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              let webArea = first(in: window, depth: 0, where: { role($0) == "AXWebArea" }),
              let url = value(webArea, kAXURLAttribute).flatMap({ ($0 as? URL) ?? URL(string: "\($0)") }),
              let host = url.host
        else { return nil }
        var page = Page(url: url.absoluteString, host: host)
        var nodes = 0
        walk(webArea, depth: 0, nodes: &nodes) { element in
            switch role(element) {
            case kAXButtonRole:
                let title = (string(element, kAXTitleAttribute) ?? "").isEmpty
                    ? (string(element, kAXDescriptionAttribute) ?? "") : (string(element, kAXTitleAttribute) ?? "")
                let id = string(element, "AXDOMIdentifier")
                if !title.isEmpty || id != nil {
                    page.buttons.append(Button(element: element, title: title.trimmingCharacters(in: .whitespaces), domID: id))
                }
            case kAXTextFieldRole:
                if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                    let count = (value(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
                        ?? string(element, kAXValueAttribute)?.count ?? 0
                    page.passwordLengths.append(count)
                } else {
                    page.otherInputs += 1
                }
            case kAXCheckBoxRole:
                page.otherInputs += 1
            case kAXStaticTextRole:
                if page.text.count < 4000, let s = string(element, kAXValueAttribute) { page.text += s + " " }
            default:
                break
            }
        }
        return page
    }

    private static func walk(_ element: AXUIElement, depth: Int, nodes: inout Int, _ visit: (AXUIElement) -> Void) {
        guard depth < 40, nodes < 4000 else { return }
        nodes += 1
        visit(element)
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, depth: depth + 1, nodes: &nodes, visit)
        }
    }

    private static func first(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if matches(element) { return element }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = first(in: child, depth: depth + 1, where: matches) { return found }
        }
        return nil
    }

    private static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Which button to press on a site's sign-in pages, if any.
enum SignInRule {
    case microsoft, google

    static func `for`(host: String) -> SignInRule? {
        switch host {
        case "login.microsoftonline.com", "login.live.com", "login.microsoft.com", "login.windows.net":
            return .microsoft
        case "accounts.google.com":
            return .google
        #if DEBUG
        // Notch's own test pages, which copy Microsoft's.
        case "localhost", "127.0.0.1":
            return .microsoft
        #endif
        default:
            return nil
        }
    }

    func buttonToPress(on page: Page) -> Page.Button? {
        let passwordFilled = !page.passwordLengths.isEmpty && page.passwordLengths.allSatisfy { $0 > 0 }
        switch self {
        case .microsoft:
            // idSIButton9 is the primary button on every page of the flow.
            let primary = page.buttons.first { $0.domID == "idSIButton9" }
                ?? page.buttons.first { ["Sign in", "Next", "Continue"].contains($0.title) }
            guard let primary else { return nil }
            if passwordFilled {
                return primary   // Sign in
            }
            // "Verification Required: you will be redirected to Duo" has
            // nothing to fill or choose, just Continue.
            if page.passwordLengths.isEmpty, page.otherInputs == 0,
               page.text.localizedCaseInsensitiveContains("redirected"), primary.title == "Continue" || primary.domID == "idSIButton9" {
                return primary
            }
            return nil
        case .google:
            guard passwordFilled else { return nil }
            return page.buttons.first { $0.domID == "passwordNext" } ?? page.buttons.first { $0.title == "Next" }
        }
    }
}
