//
//  FaceUnlockManager.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The main-actor brain of face unlock: holds UI state, owns the off-main
//  engine, and runs the state machines that drive the Face ID animation —
//  setup and "Try It" in Settings, and the real lock-screen unlock, where a
//  match has the helper type the stored login password.
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Defaults
import Foundation
import QuartzCore

@MainActor
final class FaceUnlockManager: ObservableObject {
    static let shared = FaceUnlockManager()

    /// `.testing` is Settings' "Try It" (never unlocks).
    /// `.live` runs at the real lock screen and unlocks on a match.
    enum Activity: Equatable { case idle, enrolling, testing, live }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var animationState: FaceIDAnimationState = .hidden
    @Published private(set) var status: String = ""
    @Published private(set) var isEnrolled: Bool = FaceTemplateStore.isEnrolled
    @Published private(set) var errorText: String?
    /// 0...1 while enrolling.
    @Published private(set) var enrollProgress: Double = 0
    /// Whether a login password is stored (for unlocking).
    @Published private(set) var hasPassword: Bool = false
    /// True while a password is being checked against the account and saved.
    @Published private(set) var isVerifyingPassword = false
    /// Why the last password couldn't be saved, for the password section.
    @Published private(set) var passwordError: String?

    private let engine = FaceUnlockEngine()
    private let overlay = FaceUnlockOverlayController()
    private var template: FaceTemplate? = FaceTemplateStore.load()
    private var matchStreak = 0
    private var resetTask: Task<Void, Never>?
    /// When true, the next finished capture appends to the template (adding a
    /// new lighting condition) instead of replacing it.
    private var appendOnEnroll = false
    /// Cap on stored embeddings so appending many lightings stays bounded.
    private let maxEmbeddings = 30

    /// How many consecutive live, over-threshold frames count as a match.
    private let requiredStreak = 3

    /// True from screen lock until unlock, so the async password check in
    /// startLive() doesn't start a watcher after the user already unlocked.
    private var liveRequested = false
    /// Frames seen in the current live run (for the diagnostic log).
    private var liveFrames = 0
    /// How long one lock-screen attempt scans before giving up.
    private let scanWindow: TimeInterval = 5
    /// How long Settings' "Try It" scans before giving up.
    private let tryWindow: TimeInterval = 8
    private var scanTimeoutTask: Task<Void, Never>?
    private let retryMonitor = FaceUnlockRetryShortcutMonitor()

    // Locking never starts a scan (whoever locked is usually leaving); coming
    // back does: the display or Mac waking, or touching the keyboard/trackpad.
    /// Locked and ready to unlock (enabled, enrolled, camera, password).
    private var liveReady = false
    /// The next return should start a scan. Set on lock and whenever the
    /// display sleeps; cleared once a return starts one, so a failed scan
    /// doesn't restart while the user types their password.
    private var returnPending = false
    private var displayAsleep = false
    private var lockedAt: TimeInterval = 0
    /// Input this soon after locking is the lock itself (the Touch ID or
    /// Control-Command-Q press), not someone coming back.
    private let lockGracePeriod: TimeInterval = 5
    /// Lets the camera power up after a wake before scanning.
    private let wakeScanDelay: Duration = .milliseconds(400)
    private var wakeScanTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    var previewSession: AVCaptureSession { engine.previewSession }

    private init() {
        engine.onError = { [weak self] msg in self?.handleError(msg) }
        engine.onEnrolled = { [weak self] embeddings in self?.finishEnroll(embeddings) }
        engine.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        retryMonitor.onTrigger = { [weak self] in self?.userReturned(.retryShortcut) }
        retryMonitor.onInput = { [weak self] in self?.userReturned(.input) }
        observeDisplaySleep()
        refreshPasswordState()
    }

    private var threshold: Float { Float(Defaults[.faceUnlockThreshold]) }
    private var livenessLevel: LivenessLevel { Defaults[.faceUnlockLiveness] }

    // MARK: - Control

    // In Settings the camera runs only during one of these actions, never just
    // because the page is open.

    func startEnroll() {
        FaceUnlockCamera.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.errorText = "Allow camera access to set up Face Unlock."; return }
            self.errorText = nil
            self.appendOnEnroll = false
            self.activity = .enrolling
            self.status = "Look at the camera and slowly turn your head a little."
            self.enrollProgress = 0
            self.animationState = .scanning
            self.engine.startEnroll(target: 6)
        }
    }

    /// Capture more samples under the current lighting and add them to the
    /// existing template, so matching covers this condition too.
    func addSamples() {
        guard isEnrolled else { startEnroll(); return }
        FaceUnlockCamera.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.errorText = "Allow camera access to continue."; return }
            self.errorText = nil
            self.appendOnEnroll = true
            self.activity = .enrolling
            self.status = "Look at the camera and hold still."
            self.enrollProgress = 0
            self.animationState = .scanning
            self.engine.startEnroll(target: 6)
        }
    }

    /// Settings' "Try It": scan like the lock screen does, without unlocking,
    /// and give up after a few seconds.
    func startTest() {
        guard isEnrolled else { return }
        FaceUnlockCamera.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.errorText = "Allow camera access to try Face Unlock."; return }
            self.errorText = nil
            self.activity = .testing
            self.status = "Look at the camera."
            self.matchStreak = 0
            self.animationState = .scanning
            self.engine.startRun(template: self.template, level: self.livenessLevel)
            self.resetTask?.cancel()
            self.resetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.tryWindow ?? 8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.activity == .testing, self.animationState == .scanning else { return }
                    self.animationState = .failed
                    self.status = "Didn’t recognize you. Try better lighting, or improve recognition for this lighting."
                    self.scheduleReset(after: 0.6) { $0.activity = .idle; $0.engine.stop() }
                }
            }
        }
    }

    /// Cancel whatever is running and turn the camera off.
    func stop() {
        engine.stop()
        resetTask?.cancel()
        activity = .idle
        animationState = .hidden
        status = ""
    }

    func unenroll() {
        stop()
        FaceTemplateStore.clear()
        template = nil
        isEnrolled = false
        status = "Face removed."
    }

    // MARK: - Lock-screen unlock

    func refreshPasswordState() {
        Task { [weak self] in
            let has = await NotchHelperClient.shared.hasUnlockPassword()
            await MainActor.run { self?.hasPassword = has }
        }
    }

    /// Verifies + stores the login password (helper side). The plaintext crosses
    /// XPC once here and is never read back into this app.
    func setPassword(_ password: String) {
        isVerifyingPassword = true
        passwordError = nil
        Task { [weak self] in
            let result = await NotchHelperClient.shared.storeUnlockPassword(password)
            await MainActor.run {
                guard let self else { return }
                self.isVerifyingPassword = false
                // A failed change keeps the password that was already saved.
                if result == .saved { self.hasPassword = true }
                switch result {
                case .saved: self.passwordError = nil
                case .wrongPassword: self.passwordError = "That isn’t your Mac password. Try again."
                case .saveFailed, .helperUnavailable: self.passwordError = "Couldn’t save your password. Try again."
                }
            }
        }
    }

    func clearPassword() {
        NotchHelperClient.shared.clearUnlockPassword()
        hasPassword = false
        passwordError = nil
    }

    /// Get ready to unlock at the real lock screen. Started by the app's
    /// screen-locked handler. Nothing scans yet: the first scan waits for the
    /// user to come back (see userReturned), and a match triggers the unlock.
    func startLive() {
        liveRequested = true
        lockedAt = CACurrentMediaTime()
        let enabled = Defaults[.faceUnlockEnabled]
        let cameraAuthorized = FaceUnlockCamera.isAuthorized
        Log.faceUnlock.notice("startLive: enabled=\(enabled) enrolled=\(self.isEnrolled) camera=\(cameraAuthorized)")
        guard enabled, isEnrolled, cameraAuthorized else { return }
        // Ask the helper instead of trusting `hasPassword`: that's filled in
        // asynchronously, and the first lock after launch is usually what
        // creates this manager, so the cached value would still be false.
        Task { [weak self] in
            let has = await NotchHelperClient.shared.hasUnlockPassword()
            await MainActor.run {
                guard let self else { return }
                self.hasPassword = has
                guard has, self.liveRequested else { return }
                self.liveReady = true
                self.returnPending = true
                self.displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
                Log.faceUnlock.notice("startLive: ready, waiting for the user to come back (displayAsleep=\(self.displayAsleep))")
                self.watchInputIfAwake()
            }
        }
    }

    enum ReturnSignal: String { case displayWake, input, retryShortcut }

    /// Someone may have come back to the locked Mac. A wake or the first input
    /// of a return starts one scan; the retry shortcut always does.
    private func userReturned(_ signal: ReturnSignal) {
        guard liveReady, activity != .live else { return }
        switch signal {
        case .retryShortcut:
            break
        case .displayWake, .input:
            guard returnPending, !displayAsleep else { return }
            if signal == .input, CACurrentMediaTime() - lockedAt < lockGracePeriod { return }
        }
        returnPending = false
        Log.faceUnlock.notice("user returned (\(signal.rawValue, privacy: .public)): scanning")
        beginLiveScan()
    }

    /// The keyboard/trackpad watch runs only while the screen is locked and on;
    /// with the display off, a wake notification covers the return instead.
    private func watchInputIfAwake() {
        guard liveReady, !displayAsleep, activity != .live else { return }
        retryMonitor.start(key: Defaults[.faceUnlockRetryKey])
    }

    private func observeDisplaySleep() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayWentToSleep() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayWokeUp() }
            })
        }
    }

    /// Lid closed, display off, or Mac asleep: whoever opens it next is
    /// coming back. A scan in progress can't see anyone now, so end it quietly.
    private func displayWentToSleep() {
        displayAsleep = true
        guard liveReady else { return }
        wakeScanTask?.cancel()
        retryMonitor.stop()
        if activity == .live { endLiveScan(failed: false, reason: "display went to sleep") }
        returnPending = true
    }

    /// Lid opened or display woken (both notifications arrive; the first wins).
    private func displayWokeUp() {
        guard displayAsleep else { return }
        displayAsleep = false
        guard liveReady else { return }
        wakeScanTask?.cancel()
        wakeScanTask = Task { [weak self] in
            // Input is only watched after the pause too, so a touch right as
            // the lid opens can't start the camera before it's ready.
            try? await Task.sleep(for: self?.wakeScanDelay ?? .zero)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.userReturned(.displayWake)
                self?.watchInputIfAwake()
            }
        }
    }

    /// One lock-screen attempt: scan for `scanWindow`, then give up (camera
    /// off, box collapses) so the user types their password, as on an iPhone.
    /// The retry shortcut starts another attempt.
    private func beginLiveScan() {
        guard liveRequested, activity != .live else { return }
        retryMonitor.stop()
        wakeScanTask?.cancel()
        resetTask?.cancel()
        activity = .live
        matchStreak = 0
        liveFrames = 0
        // The rings wait for the camera's first frame (see handleFrame), so
        // the box is never up while the camera is still off.
        animationState = .hidden
        overlay.show()
        engine.startRun(template: template, level: livenessLevel)
        // Re-armed on the first frame, so a slow camera start doesn't eat the
        // window; this first arming covers a camera that never delivers.
        armScanTimeout()
    }

    private func armScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.scanWindow ?? 5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activity == .live, self.animationState != .matched else { return }
                self.endLiveScan(failed: true, reason: self.liveFrames == 0
                                 ? "camera delivered no frames" : "no match in \(Int(self.scanWindow))s")
            }
        }
    }

    /// Stop scanning but stay ready (still locked): the password field is
    /// untouched, and the retry shortcut can start a new scan.
    private func endLiveScan(failed: Bool, reason: String) {
        guard activity == .live else { return }
        Log.faceUnlock.notice("scan ended after \(self.liveFrames) frames: \(reason, privacy: .public)")
        scanTimeoutTask?.cancel()
        activity = .idle
        if failed, animationState == .scanning {
            // Shake, then collapse; the camera stays on until the box is gone
            // so the rings are never showing with the camera off.
            animationState = .failed
            scheduleReset(after: 0.6) { $0.engine.stop() }
        } else {
            animationState = .hidden
            engine.stop()
        }
        watchInputIfAwake()
    }

    /// Stop the live watcher (screen unlocked, by us or by the user).
    func stopLive() {
        liveRequested = false
        liveReady = false
        returnPending = false
        wakeScanTask?.cancel()
        retryMonitor.stop()
        scanTimeoutTask?.cancel()
        overlay.hide()
        // .failed is an unlock during the give-up shake, whose camera is
        // still on until its pending reset; stop it now instead.
        guard activity == .live || animationState == .failed else { return }
        Log.faceUnlock.notice("stopLive after \(self.liveFrames) frames")
        engine.stop()
        resetTask?.cancel()
        activity = .idle
        animationState = .hidden
    }

    // MARK: - Engine callbacks

    private func handleFrame(_ frame: FaceUnlockEngine.Frame) {
        switch activity {
        case .enrolling:
            enrollProgress = Double(frame.similarity)
        case .testing, .live:
            if activity == .live {
                liveFrames += 1
                if liveFrames == 1 {
                    armScanTimeout()                // the window counts from the first frame
                    animationState = .scanning      // the camera is really on: show the rings
                }
            }
            let matching = frame.faceFound && frame.similarity >= threshold && frame.isLive
            matchStreak = matching ? matchStreak + 1 : 0
            if matchStreak >= requiredStreak, animationState == .scanning {
                if activity == .live { matchedLive() } else { matched() }
            }
        case .idle:
            break
        }
    }

    /// "Try It" match: the checkmark plays over the live preview, then the
    /// camera turns off.
    private func matched() {
        animationState = .matched
        status = "Recognized you ✓"
        engine.idle()   // camera stays on (preview showing) until the reset
        scheduleReset(after: 1.4) { $0.activity = .idle; $0.engine.stop() }
    }

    /// Lock-screen match: play the checkmark and type the stored password. A
    /// real unlock ends via stopLive(); if the screen is still locked after a
    /// short pause (the typing was refused or didn't take), the scan ends and
    /// the retry shortcut is armed.
    private func matchedLive() {
        animationState = .matched
        scanTimeoutTask?.cancel()
        engine.stop()
        Log.faceUnlock.notice("live match after \(self.liveFrames) frames")
        Task {
            let ok = await NotchHelperClient.shared.unlockScreenWithStoredPassword()
            Log.faceUnlock.notice("unlock request returned \(ok)")
        }
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activity == .live else { return }  // unlocked -> stopLive ran
                self.endLiveScan(failed: false, reason: "matched, still locked")
            }
        }
    }

    private func finishEnroll(_ embeddings: [[Float]]) {
        guard !embeddings.isEmpty else {
            handleError("Couldn't capture a clear face. Try better lighting.")
            return
        }
        let appended = appendOnEnroll
        appendOnEnroll = false
        let base = (appended ? template?.embeddings : nil) ?? []
        let merged = Array((base + embeddings).suffix(maxEmbeddings))
        let template = FaceTemplate(embeddings: merged, createdAt: Date())
        FaceTemplateStore.save(template)
        self.template = template
        isEnrolled = true
        activity = .idle
        engine.stop()   // done with the camera; the preview is gone with .idle
        enrollProgress = 1
        animationState = .matched
        status = appended ? "Recognition improved for this lighting ✓" : "Face Unlock is set up ✓"
        scheduleReset(after: 1.2) { _ in }
    }

    private func handleError(_ msg: String) {
        Log.faceUnlock.error("engine error (activity=\(String(describing: self.activity), privacy: .public)): \(msg, privacy: .public)")
        let wasLive = activity == .live
        engine.stop()
        resetTask?.cancel()
        scanTimeoutTask?.cancel()
        errorText = msg
        status = ""
        activity = .idle
        animationState = .hidden
        // At the lock screen, leave a way to try again.
        if wasLive { watchInputIfAwake() }
    }

    private func scheduleReset(after seconds: Double, _ extra: @escaping (FaceUnlockManager) -> Void) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.animationState = .hidden
                extra(self)
            }
        }
    }
}

#if DEBUG
extension FaceUnlockManager {
    /// Demo mode: play the lock-screen Face ID animation on the desktop, in
    /// the real overlay window: scan, match, then collapse.
    func demoFaceID() {
        animationState = .hidden
        overlay.show()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.animationState = .scanning
            try? await Task.sleep(for: .milliseconds(2000))
            self?.animationState = .matched
            try? await Task.sleep(for: .milliseconds(1700))
            self?.animationState = .hidden
            try? await Task.sleep(for: .milliseconds(900))
            self?.overlay.hide()
        }
    }
}
#endif
