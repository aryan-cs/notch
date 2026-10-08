//
//  UserActivityMonitor.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Whether someone's using the Mac right now: unlocked, displays awake, no
//  screen saver, this login session in front, and input within the last few
//  minutes. The presence guard only watches while that holds.
//
//  Lock, sleep and session changes arrive as notifications. Idle time has no
//  notification, so it's read every few seconds — only while the screen is
//  unlocked and awake, and only while the guard is running.
//

import AppKit
import CoreGraphics

struct UserActivityState: Equatable {
    /// No input for this long counts as away.
    static let idleLimit: TimeInterval = 3 * 60

    var isLocked = false
    var displaysAsleep = false
    var systemAsleep = false
    var screenSaverRunning = false
    /// Another user's session is in front (fast user switching).
    var sessionInactive = false
    var idleSeconds: TimeInterval = 0

    var isActive: Bool {
        isAwake && !screenSaverRunning && idleSeconds < Self.idleLimit
    }

    /// Idle time only matters, and is only read, while this holds.
    var isAwake: Bool {
        !isLocked && !displaysAsleep && !systemAsleep && !sessionInactive
    }
}

@MainActor
final class UserActivityMonitor: UserActivityMonitoring {
    static let pollInterval: TimeInterval = 5

    var onChange: ((Bool) -> Void)?
    private(set) var state = UserActivityState()
    var isActive: Bool { state.isActive }

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?

    func start() {
        guard observers.isEmpty else { return }
        state = UserActivityState()
        state.isLocked = ScreenLock.isLocked
        state.idleSeconds = Self.secondsSinceInput()

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.isLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") {
            $0.isLocked = false
            $0.idleSeconds = 0  // They just typed their password.
        }
        observe(distributed, "com.apple.screensaver.didstart") { $0.screenSaverRunning = true }
        observe(distributed, "com.apple.screensaver.didstop") { $0.screenSaverRunning = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionInactive = false }
        updatePolling()
    }

    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping @Sendable (inout UserActivityState) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(change) }
        }
        observers.append((center, token))
    }

    private func update(_ change: (inout UserActivityState) -> Void) {
        let wasActive = state.isActive
        change(&state)
        updatePolling()
        if state.isActive != wasActive {
            onChange?(state.isActive)
        }
    }

    private func updatePolling() {
        guard state.isAwake else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update { $0.idleSeconds = Self.secondsSinceInput() }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Seconds since the last keyboard, mouse or trackpad input in this session.
    private static func secondsSinceInput() -> TimeInterval {
        // ~0 is kCGAnyInputEventType.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
