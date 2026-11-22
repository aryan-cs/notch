//
//  SignInPageWatcher.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Starts a Microsoft sign-in as soon as its password step opens, instead of
//  waiting for you to pick your saved password. With Chrome asking for
//  Touch ID before it fills a password, that step opens with the password
//  field focused and your saved password offered in a list under it. This
//  tells the app, which starts looking for your face right away, and presses
//  the saved password for the account the page shows. That brings up
//  Chrome's Touch ID prompt for Face Unlock to answer (TouchIDPromptWatcher),
//  usually after the face check is already done.
//
//  It only looks while a Chromium browser in front has a password field
//  focused (the browser then holds secure keyboard input, which costs nothing
//  to check), reads that page, and starts each page at most once.
//

import AppKit
import ApplicationServices

final class SignInPageWatcher: @unchecked Sendable {
    static let shared = SignInPageWatcher()

    private static let interval: DispatchTimeInterval = .milliseconds(250)
    /// How long a page gets to show up through Accessibility once it's asked for.
    private static let pageWait: TimeInterval = 2
    /// How long Chrome gets to offer the saved password under the field, and
    /// to take the pick.
    private static let listWait: TimeInterval = 3
    /// Chromium ignores picks in that list for its first half second, so
    /// they can't be clicked by accident (or by a page) as it appears.
    private static let listSettle: TimeInterval = 0.6

    private let queue = DispatchQueue(label: "Notch.signInPageWatcher")
    private var timer: DispatchSourceTimer?
    /// Told about each page it starts, with "browser" (its name) and "host";
    /// false means not to go on, and leave the page to you.
    private var onPage: (([String: String]) -> Bool)?
    /// The browser whose password field has the keyboard, and since when.
    private var focus: (pid: pid_t, since: Date)?
    /// Whether that page has been looked at.
    private var looked = false
    private var holdsWebAccessibility = false
    /// Pages already started.
    private var started: [String] = []

    func start(onPage: @escaping ([String: String]) -> Bool) {
        queue.async { [self] in
            self.onPage = onPage
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            Log.helper.notice("Watching for Microsoft password steps")
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            onPage = nil
            endFocus()
        }
    }

    private func poll() {
        guard let pid = TouchIDPromptWatcher.secureInputOwner(), pid == SignInAssistant.frontmostPID(),
              let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier,
              SignInAssistant.chromiumBrowsers.contains(id)
        else { return endFocus() }
        if focus?.pid != pid {
            endFocus()
            focus = (pid, Date())
            holdsWebAccessibility = WebAccessibility.hold(app)
        }
        guard !looked, let since = focus?.since else { return }
        // Right after Accessibility is asked for, the page can take a moment
        // to fill in; the focused password field says when it has.
        guard let page = Page.read(pid: pid), !page.passwordLengths.isEmpty else {
            if Date().timeIntervalSince(since) > Self.pageWait { stopLooking() }
            return
        }
        looked = true
        guard SignInRule.for(host: page.host) == .microsoft, page.passwordLengths == [0], !started.contains(page.url) else {
            return stopLooking()
        }
        started = Array((started + [page.url]).suffix(20))
        Log.helper.notice("Microsoft password step open in \(id, privacy: .public): starting the sign-in")
        guard onPage?(["browser": app.localizedName ?? "", "host": page.host]) == true else { return stopLooking() }
        pickSavedPassword(pid: pid, accounts: page.emailAddresses)
    }

    /// Done with this page, though its field still has the keyboard.
    private func stopLooking() {
        looked = true
        if holdsWebAccessibility, let pid = focus?.pid { WebAccessibility.release(pid) }
        holdsWebAccessibility = false
    }

    private func endFocus() {
        stopLooking()
        focus = nil
        looked = false
    }

    // MARK: - Picking the saved password

    /// Presses the saved password for one of `accounts` (the ones the page
    /// shows) in the list Chrome opens under the field. Without an account on
    /// the page, or without the list, picking is left to you.
    private func pickSavedPassword(pid: pid_t, accounts: [String]) {
        guard !accounts.isEmpty else {
            Log.helper.notice("No account on the page; leaving the saved password to you")
            return
        }
        let deadline = Date().addingTimeInterval(Self.listWait)
        var shown: Date?
        var lastPress: Date?
        var presses = 0
        repeat {
            guard let entry = Self.savedPasswordEntry(pid: pid, for: accounts) else {
                // The list closes once a pick is taken.
                if presses > 0 {
                    Log.helper.notice("Picked the saved password after \(presses, privacy: .public) press(es)")
                    return
                }
                usleep(100_000)
                continue
            }
            let now = Date()
            if shown == nil { shown = now }
            if let shown, now.timeIntervalSince(shown) >= Self.listSettle,
               lastPress.map({ now.timeIntervalSince($0) >= 0.5 }) ?? true {
                guard SignInAssistant.frontmostPID() == pid else { return }
                AXUIElementPerformAction(entry, kAXPressAction as CFString)
                lastPress = now
                presses += 1
            }
            usleep(50_000)
        } while Date() < deadline
        if shown == nil {
            Log.helper.notice("The browser didn't offer a saved password for the account")
        } else {
            Log.helper.notice("The browser didn't take the saved password pick")
        }
    }

    /// The list under the field is a window of its own; its entries read
    /// like "Password for name@example.com".
    private static func savedPasswordEntry(pid: pid_t, for accounts: [String]) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for window in Page.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        where Page.string(window, kAXSubroleAttribute) != kAXStandardWindowSubrole {
            let entry = Page.first(in: window, depth: 0) { element in
                guard Page.role(element) == kAXStaticTextRole, let text = Page.string(element, kAXValueAttribute),
                      accounts.contains(where: { text.localizedCaseInsensitiveContains($0) })
                else { return false }
                var actions: CFArray?
                return AXUIElementCopyActionNames(element, &actions) == .success
                    && (actions as? [String])?.contains(kAXPressAction) == true
            }
            if let entry { return entry }
        }
        return nil
    }
}
