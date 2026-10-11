//
//  FaceApproval.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock standing in for your password outside the lock screen, in
//  two places:
//
//  - sudo, anywhere in your login session. Its PAM module asks NotchHelper,
//    which asks this. See NotchSudo/pam_notch.c and
//    NotchHelper/SudoRequestListener.swift.
//  - The system's Touch ID prompts ("Google Chrome is trying to verify it's
//    you…", administrator prompts). NotchHelper notices them and, once
//    approved, fills in your saved password. See
//    NotchHelper/TouchIDPromptWatcher.swift.
//
//  Either way the notch drops down with the Face ID box, looks for your face,
//  and, after you double-tap the Try again key if Settings says to confirm,
//  answers yes. Anything else and you use your password (or Touch ID) as
//  usual.
//

import Combine
import Defaults
import Foundation

@MainActor
final class FaceApproval: ObservableObject {
    static let shared = FaceApproval()

    /// What's asking.
    enum Kind {
        case sudo
        case touchIDPrompt
    }

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
    /// Why turning the sudo integration on or off failed.
    @Published private(set) var integrationError: String?

    /// The request being handled, if any. Only one at a time.
    private var current: (id: String, phase: Phase)?

    /// How long to wait for a confirmation after a match.
    private let confirmWindow: Duration = .seconds(10)
    private let confirmShortcut = FaceUnlockRetryShortcutMonitor()
    private var reply: ((Bool) -> Void)?
    private var confirmTimeout: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        confirmShortcut.onTrigger = { [weak self] in self?.allow() }
    }

    var isSudoOn: Bool {
        switch integrationStatus {
        case .on, .outdated, .updateAvailable: return true
        case .off, nil: return false
        }
    }

    /// Called at launch: starts listening for sudo and watching for Touch ID
    /// prompts if they're turned on, and again whenever the helper restarts.
    func start() {
        Task { await connectToHelper() }
        NotchHelperClient.shared.$helperAvailable
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.connectToHelper()
                }
            }
            .store(in: &cancellables)
        Defaults.publisher(.faceUnlockTouchIDPrompts, options: [])
            .sink { [weak self] _ in Task { @MainActor in await self?.updateTouchIDPromptWatching() } }
            .store(in: &cancellables)
    }

    private func connectToHelper() async {
        await refreshStatus()
        await updateTouchIDPromptWatching()
    }

    func refreshStatus() async {
        integrationStatus = await NotchHelperClient.shared.sudoIntegrationStatus()
        #if DEBUG
        // Development builds always listen, so the PAM module's test harness
        // can reach them before anything is installed.
        let listen = true
        #else
        let listen = isSudoOn
        #endif
        if listen {
            _ = await NotchHelperClient.shared.startSudoListener()
        }
    }

    private func updateTouchIDPromptWatching() async {
        if Defaults[.faceUnlockTouchIDPrompts] {
            _ = await NotchHelperClient.shared.startTouchIDPromptWatching()
        } else {
            NotchHelperClient.shared.stopTouchIDPromptWatching()
        }
    }

    /// Turns the sudo integration on or off; macOS asks for an administrator
    /// password either way.
    func setSudoIntegrationEnabled(_ enabled: Bool) {
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

    /// Something is waiting for approval. `reply` goes back to it: true lets
    /// sudo run, or has the helper fill in the Touch ID prompt.
    func handle(id: String, kind: Kind, requester: String?, reply: @escaping (Bool) -> Void) {
        // One at a time; the screen has to be in use, not locked or asleep.
        guard current == nil, !ScreenLock.isLocked else {
            reply(false)
            return
        }
        // (The helper only asks about Touch ID prompts when a password is saved.)
        if kind == .touchIDPrompt, !Defaults[.faceUnlockTouchIDPrompts] {
            reply(false)
            return
        }
        let started = FaceUnlockManager.shared.startApprovalScan { [weak self] matched in
            self?.scanFinished(matched: matched)
        }
        guard started else {
            reply(false)
            return
        }
        Log.faceUnlock.notice("approval requested by \(requester ?? "unknown", privacy: .public)")
        dismissTask?.cancel()
        self.reply = reply
        current = (id, .scanning)
        if kind == .sudo {
            NotchHelperClient.shared.sudoRequestDidStartScanning(id)
        }
    }

    /// The request went away: sudo was cancelled, or the Touch ID prompt was
    /// answered some other way.
    func cancel(id: String) {
        guard let current, current.id == id else { return }
        reply = nil
        if current.phase == .scanning {
            FaceUnlockManager.shared.cancelApprovalScan()   // reports no match, which finishes
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
        guard Defaults[.faceUnlockApprovalsRequireConfirmation] else {
            finish(allowed: true)
            return
        }
        let key = Defaults[.faceUnlockRetryKey]
        guard key != .off else {
            // Nothing to confirm with, so this falls back to the password.
            Log.faceUnlock.notice("confirmation is on but the Try again key is off")
            finish(allowed: false)
            return
        }
        // The green check stays up while it waits for the double tap.
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
        Log.faceUnlock.notice("approval \(allowed ? "given" : "not given", privacy: .public)")
        reply?(allowed)
        reply = nil
        current?.phase = .done
        // Long enough to see the checkmark, or the shake on a failed scan.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(allowed ? 1000 : 700))
            guard !Task.isCancelled, let self else { return }
            self.current = nil
            FaceUnlockManager.shared.hideApprovalAnimation()
        }
    }
}
