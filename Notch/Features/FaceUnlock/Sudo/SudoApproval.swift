//
//  SudoApproval.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock for sudo, on the app's side. When sudo runs anywhere in your
//  login session (a terminal, a script, an AI agent), its PAM module asks
//  NotchHelper, which asks this. Notch shows the same Face ID box as the
//  lock screen, looks for your face, and, after you double-tap the Try
//  again key if Settings says to confirm, tells sudo to go ahead. Anything
//  else and sudo asks for your password as usual.
//
//  The sudo side lives in NotchSudo/pam_notch.c, and the helper's in
//  NotchHelper/SudoRequestListener.swift and SudoIntegration.swift.
//

import Combine
import Defaults
import Foundation

@MainActor
final class SudoApproval: ObservableObject {
    static let shared = SudoApproval()

    /// Where the request being handled is.
    enum Phase: Equatable {
        /// Looking for a face.
        case scanning
        /// Recognized; waiting for the confirm shortcut.
        case confirming
        /// Answered; the Face ID box is on its way out.
        case done
    }

    /// Whether sudo asks Notch first. Nil until the helper has answered.
    @Published private(set) var integrationStatus: SudoIntegrationStatus?
    /// True while the administrator prompt is up.
    @Published private(set) var isChangingIntegration = false
    /// Why turning the integration on or off failed.
    @Published private(set) var integrationError: String?
    /// The request being handled, if any. Only one at a time.
    private var current: (id: String, phase: Phase)?

    /// How long to wait for a confirmation after a match.
    private let confirmWindow: Duration = .seconds(10)
    private let confirmShortcut = FaceUnlockRetryShortcutMonitor()
    private var reply: ((Bool) -> Void)?
    private var confirmTimeout: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var helperObserver: AnyCancellable?

    private init() {
        confirmShortcut.onTrigger = { [weak self] in self?.allow() }
    }

    var isOn: Bool {
        switch integrationStatus {
        case .on, .outdated, .updateAvailable: return true
        case .off, nil: return false
        }
    }

    /// Called at launch: listens for sudo if the integration is on, and again
    /// whenever the helper restarts.
    func start() {
        Task { await refreshStatus() }
        helperObserver = NotchHelperClient.shared.$helperAvailable
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.refreshStatus()
                }
            }
    }

    func refreshStatus() async {
        integrationStatus = await NotchHelperClient.shared.sudoIntegrationStatus()
        #if DEBUG
        // Development builds always listen, so the PAM module's test harness
        // can reach them before anything is installed.
        let listen = true
        #else
        let listen = isOn
        #endif
        if listen {
            _ = await NotchHelperClient.shared.startSudoListener()
        }
    }

    /// Turns the integration on or off; macOS asks for an administrator
    /// password either way.
    func setIntegrationEnabled(_ enabled: Bool) {
        guard !isChangingIntegration else { return }
        isChangingIntegration = true
        integrationError = nil
        Task {
            let result = await NotchHelperClient.shared.setSudoIntegrationEnabled(enabled)
            isChangingIntegration = false
            if !result.succeeded, let message = result.message {
                integrationError = message
            }
            if !enabled, result.succeeded {
                NotchHelperClient.shared.stopSudoListener()
            }
            await refreshStatus()
        }
    }

    // MARK: - Requests

    /// A sudo is waiting. `reply` goes back to it: true lets it run.
    func handle(id: String, command: String, requester: String?, reply: @escaping (Bool) -> Void) {
        // One at a time; the screen has to be in use, not locked or asleep.
        guard current == nil, !ScreenLock.isLocked else {
            reply(false)
            return
        }
        let started = FaceUnlockManager.shared.startSudoScan { [weak self] matched in
            self?.scanFinished(matched: matched)
        }
        guard started else {
            reply(false)
            return
        }
        Log.faceUnlock.notice("sudo approval requested by \(requester ?? "unknown", privacy: .public)")
        dismissTask?.cancel()
        self.reply = reply
        current = (id, .scanning)
        NotchHelperClient.shared.sudoRequestDidStartScanning(id)
    }

    /// The sudo went away (Control-C, or it timed out).
    func cancel(id: String) {
        guard let current, current.id == id else { return }
        reply = nil
        if current.phase == .scanning {
            FaceUnlockManager.shared.cancelSudoScan()   // reports no match, which finishes
        } else {
            finish(allowed: false)
        }
    }

    private func scanFinished(matched: Bool) {
        guard current?.phase == .scanning else { return }
        guard matched else {
            finish(allowed: false)
            return
        }
        guard Defaults[.faceUnlockSudoRequiresConfirmation] else {
            finish(allowed: true)
            return
        }
        let key = Defaults[.faceUnlockRetryKey]
        guard key != .off else {
            // Nothing to confirm with, so sudo falls back to the password.
            Log.faceUnlock.notice("sudo confirmation is on but the Try again key is off")
            finish(allowed: false)
            return
        }
        // The green check stays up while sudo waits for the double tap.
        current?.phase = .confirming
        confirmShortcut.start(key: key)
        confirmTimeout = Task { [weak self, confirmWindow] in
            try? await Task.sleep(for: confirmWindow)
            guard !Task.isCancelled else { return }
            self?.finish(allowed: false)
        }
    }

    /// The confirm shortcut.
    private func allow() {
        guard current?.phase == .confirming else { return }
        finish(allowed: true)
    }

    private func finish(allowed: Bool) {
        guard let phase = current?.phase, phase == .scanning || phase == .confirming else { return }
        confirmTimeout?.cancel()
        confirmShortcut.stop()
        Log.faceUnlock.notice("sudo \(allowed ? "allowed" : "not allowed", privacy: .public)")
        reply?(allowed)
        reply = nil
        current?.phase = .done
        // Long enough to see the checkmark, or the shake on a failed scan.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(allowed ? 1000 : 700))
            guard !Task.isCancelled, let self else { return }
            self.current = nil
            FaceUnlockManager.shared.hideSudoAnimation()
        }
    }
}
