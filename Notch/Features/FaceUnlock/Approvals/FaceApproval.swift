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
//  usual. A Touch ID prompt stays up after a failed scan, so there, as on
//  the lock screen, the Try again key scans again.
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
        /// Not recognized, but the Touch ID prompt is still up; waiting for
        /// the Try again key.
        case waitingForRetry
        /// Answered; the Face ID box is on its way out.
        case done
    }

    private struct Request {
        let id: String
        let kind: Kind
        var phase: Phase
        /// What asked went away, so there's nothing to retry.
        var isCancelled = false
    }

    /// Whether sudo asks Notch first. Nil until the helper has answered.
    @Published private(set) var integrationStatus: SudoIntegrationStatus?
    /// True while the administrator prompt is up.
    @Published private(set) var isChangingIntegration = false
    /// Why turning the sudo integration on or off failed.
    @Published private(set) var integrationError: String?

    /// The request being handled, if any. Only one at a time.
    private var current: Request?

    /// How long to wait for a confirmation after a match.
    private let confirmWindow: Duration = .seconds(10)
    /// How long a Touch ID prompt can wait for the Try again key. It's
    /// normally closed long before, which ends the wait.
    private let retryWindow: Duration = .seconds(120)
    /// The Try again key: confirms a match, or scans again after a miss.
    private let shortcut = FaceUnlockRetryShortcutMonitor()
    private var reply: ((Bool) -> Void)?
    private var shortcutTimeout: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        shortcut.onTrigger = { [weak self] in self?.shortcutTapped() }
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
        guard startScan() else {
            reply(false)
            return
        }
        Log.faceUnlock.notice("approval requested by \(requester ?? "unknown", privacy: .public)")
        dismissTask?.cancel()
        self.reply = reply
        current = Request(id: id, kind: kind, phase: .scanning)
        if kind == .sudo {
            NotchHelperClient.shared.sudoRequestDidStartScanning(id)
        }
    }

    /// The request went away: sudo was cancelled, or the Touch ID prompt was
    /// answered some other way.
    func cancel(id: String) {
        guard let request = current, request.id == id else { return }
        reply = nil
        current?.isCancelled = true
        if request.phase == .scanning {
            FaceUnlockManager.shared.cancelApprovalScan()   // reports no match, which finishes
        } else {
            finish(allowed: false)
        }
    }

    private func startScan() -> Bool {
        FaceUnlockManager.shared.startApprovalScan { [weak self] matched in
            self?.scanFinished(matched: matched)
        }
    }

    private func scanFinished(matched: Bool) {
        guard let request = current, request.phase == .scanning else { return }
        guard matched else {
            let retryKey = Defaults[.faceUnlockRetryKey]
            if request.kind == .touchIDPrompt, !request.isCancelled, retryKey != .off {
                waitForRetry(key: retryKey)
            } else {
                finish(allowed: false)
            }
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
        listenForShortcut(key: key, for: confirmWindow)
    }

    /// The prompt stays up after a miss, so the box shakes and folds away
    /// and the Try again key can bring it back, as on the lock screen.
    private func waitForRetry(key: FaceUnlockRetryKey) {
        current?.phase = .waitingForRetry
        listenForShortcut(key: key, for: retryWindow)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, self?.current?.phase == .waitingForRetry else { return }
            FaceUnlockManager.shared.hideApprovalAnimation()
        }
    }

    private func listenForShortcut(key: FaceUnlockRetryKey, for window: Duration) {
        shortcut.start(key: key)
        shortcutTimeout?.cancel()
        shortcutTimeout = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.finish(allowed: false)
        }
    }

    private func shortcutTapped() {
        switch current?.phase {
        case .confirming:
            finish(allowed: true)
        case .waitingForRetry:
            // Fails if Face Unlock is busy (say, the screen just locked);
            // then it keeps waiting.
            guard startScan() else { return }
            Log.faceUnlock.notice("approval scan retried")
            shortcut.stop()
            shortcutTimeout?.cancel()
            dismissTask?.cancel()
            current?.phase = .scanning
        default:
            break
        }
    }

    private func finish(allowed: Bool) {
        guard let phase = current?.phase, phase != .done else { return }
        shortcutTimeout?.cancel()
        shortcut.stop()
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
