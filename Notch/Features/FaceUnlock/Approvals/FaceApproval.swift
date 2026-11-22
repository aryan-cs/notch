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
//    you…", administrator prompts), and its password-only prompts ("Allow
//    administrator access"). NotchHelper notices them and, once approved,
//    fills in your saved password. See NotchHelper/TouchIDPromptWatcher.swift.
//
//  Either way the notch grows a Face ID animation on its right, looks for your face,
//  and, after you double-tap the Try again key if Settings says to confirm,
//  answers yes. Anything else and you use your password (or Touch ID) as
//  usual. A prompt stays up after a failed scan, so there, as on
//  the lock screen, the Try again key scans again.
//
//  For Microsoft sign-ins in Chromium browsers it can start before the prompt
//  does: the helper notices the password step opening (SignInPageWatcher),
//  the scan starts then, and the browser's Touch ID prompt, when it comes
//  within a few seconds and names the same browser and site, takes that
//  scan's answer instead of starting its own.
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
        /// A system prompt that only takes a password, like "Allow
        /// administrator access".
        case passwordPrompt
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
        /// Recognized before the Touch ID prompt it's for came up; waiting
        /// for it.
        case waitingForPrompt
        /// Answered; the Face ID box is on its way out.
        case done
    }

    private struct Request {
        var id: String
        let kind: Kind
        var phase: Phase
        /// What asked went away, so there's nothing to retry.
        var isCancelled = false
        /// Set while a scan started early waits for its Touch ID prompt.
        var expected: ExpectedPrompt?
    }

    /// The Touch ID prompt a sign-in page is about to bring up.
    private struct ExpectedPrompt {
        let browser: String
        let host: String

        /// The prompt names both, as in "Google Chrome.app is trying to fill
        /// your password on login.microsoftonline.com."
        func matches(_ reason: String) -> Bool {
            !browser.isEmpty && !host.isEmpty && reason.contains(browser) && reason.contains(host)
        }
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
    /// How long a scan started early waits for its prompt.
    private let earlyWindow: Duration = .seconds(10)
    private var earlyTimeout: Task<Void, Never>?
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
        Defaults.publisher(keys: .faceUnlockTouchIDPrompts, .faceUnlockPasswordPrompts, .faceUnlockSignInAssist,
                           .faceUnlockSignInEarly, options: [])
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
        if Defaults[.faceUnlockTouchIDPrompts] || Defaults[.faceUnlockPasswordPrompts] {
            _ = await NotchHelperClient.shared.startTouchIDPromptWatching()
        } else {
            NotchHelperClient.shared.stopTouchIDPromptWatching()
        }
        let signInAssist = Defaults[.faceUnlockTouchIDPrompts] && Defaults[.faceUnlockSignInAssist]
        NotchHelperClient.shared.setSignInAssistEnabled(signInAssist)
        NotchHelperClient.shared.setEarlySignInEnabled(signInAssist && Defaults[.faceUnlockSignInEarly])
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
        if adoptEarlyRequest(id: id, kind: kind, requester: requester, reply: reply) { return }
        // Some other prompt: the early scan gives way to it.
        dropEarlyRequest(reason: "a different prompt came")
        // One at a time; the screen has to be in use, not locked or asleep.
        guard current == nil, !ScreenLock.isLocked else {
            reply(false)
            return
        }
        // (The helper only asks about Touch ID prompts when a password is saved.)
        if (kind == .touchIDPrompt && !Defaults[.faceUnlockTouchIDPrompts])
            || (kind == .passwordPrompt && !Defaults[.faceUnlockPasswordPrompts]) {
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

    // MARK: Starting early

    /// A Microsoft password step just opened in `browser`, which is about to
    /// ask for Touch ID before filling your password; looks for your face now
    /// so the answer is ready when it does.
    func prepareForSignIn(browser: String, host: String) {
        guard current == nil, !ScreenLock.isLocked, Defaults[.faceUnlockTouchIDPrompts], startScan() else { return }
        Log.faceUnlock.notice("approval scan started early for a sign-in on \(host, privacy: .public)")
        dismissTask?.cancel()
        reply = nil
        current = Request(id: "early-\(UUID().uuidString)", kind: .touchIDPrompt, phase: .scanning,
                          expected: ExpectedPrompt(browser: browser, host: host))
        earlyTimeout?.cancel()
        earlyTimeout = Task { [weak self] in
            try? await Task.sleep(for: self?.earlyWindow ?? .seconds(10))
            guard !Task.isCancelled else { return }
            self?.dropEarlyRequest(reason: "no Touch ID prompt came")
        }
    }

    /// The Touch ID prompt an early scan was waiting for. True if it's taken.
    private func adoptEarlyRequest(id: String, kind: Kind, requester: String?, reply: @escaping (Bool) -> Void) -> Bool {
        guard let request = current, let expected = request.expected, kind == .touchIDPrompt,
              let requester, expected.matches(requester), !ScreenLock.isLocked
        else { return false }
        earlyTimeout?.cancel()
        dismissTask?.cancel()
        self.reply = reply
        current?.id = id
        current?.expected = nil
        Log.faceUnlock.notice("approval requested by \(requester, privacy: .public) (scan already \(request.phase == .scanning ? "running" : "done", privacy: .public))")
        if request.phase == .waitingForPrompt {
            finish(allowed: true)
        }
        return true
    }

    /// An early scan that won't be used: no match, or no prompt came.
    private func dropEarlyRequest(reason: String) {
        guard let request = current, request.expected != nil else { return }
        Log.faceUnlock.notice("early approval scan dropped: \(reason, privacy: .public)")
        earlyTimeout?.cancel()
        shortcutTimeout?.cancel()
        shortcut.stop()
        current = nil
        if request.phase == .scanning {
            FaceUnlockManager.shared.cancelApprovalScan()
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self?.current == nil else { return }
            FaceUnlockManager.shared.hideApprovalAnimation()
        }
    }

    /// Recognized before the prompt came up.
    private func waitForPrompt() {
        current?.phase = .waitingForPrompt
        // The check doesn't need to stay up the whole time; the prompt
        // normally comes within a second.
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.current?.phase == .waitingForPrompt else { return }
            FaceUnlockManager.shared.hideApprovalAnimation()
        }
    }

    // MARK: Ending

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
        if request.expected != nil, !matched {
            // Its prompt isn't up yet, so there's nothing to retry; when it
            // comes it gets a scan of its own.
            dropEarlyRequest(reason: "no match")
            return
        }
        guard matched else {
            let retryKey = Defaults[.faceUnlockRetryKey]
            if request.kind != .sudo, !request.isCancelled, retryKey != .off {
                waitForRetry(key: retryKey)
            } else {
                finish(allowed: false)
            }
            return
        }
        guard Defaults[.faceUnlockApprovalsRequireConfirmation] else {
            if request.expected != nil { waitForPrompt() } else { finish(allowed: true) }
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
            if current?.expected != nil {
                shortcut.stop()
                shortcutTimeout?.cancel()
                waitForPrompt()
            } else {
                finish(allowed: true)
            }
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
        earlyTimeout?.cancel()
        shortcutTimeout?.cancel()
        shortcut.stop()
        Log.faceUnlock.notice("approval \(allowed ? "given" : "not given", privacy: .public)")
        reply?(allowed)
        reply = nil
        current?.phase = .done
        // Long enough to see the checkmark draw (0.57 s), or the shake (0.4 s).
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(allowed ? 650 : 500))
            guard !Task.isCancelled, let self else { return }
            self.current = nil
            FaceUnlockManager.shared.hideApprovalAnimation()
        }
    }
}
