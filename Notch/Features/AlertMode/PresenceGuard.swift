//
//  PresenceGuard.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Alert mode: while you're using your Mac somewhere public, turn on Do Not
//  Disturb when someone else is plausibly close enough to read your screen,
//  and turn it off again when they've gone.
//
//  Bluetooth does the watching — it's cheap and has no light. Only when it
//  hears more Apple devices close by than usual does the camera come on, for
//  about two seconds, to look for a second face. Focus is switched with two
//  shortcuts the user makes (FocusShortcut), run by the XPC helper.
//
//  Nothing runs unless the feature is enabled in Settings AND Alert mode is
//  on (the header's button): no scanning, no camera, no timers. The
//  decisions live in PresenceGuardMachine; this carries them out.
//

import AVFoundation
import Combine
import Defaults
import Foundation

/// What the guard is doing, for the header's Alert button and Settings.
enum PresenceGuardState: Equatable {
    /// Alert mode is off, or the feature is disabled. Nothing runs.
    case off
    /// Alert mode is on, but you're away, the screen is locked or asleep,
    /// or Bluetooth is off or not allowed.
    case paused
    /// Listening for devices nearby, including the first seconds of
    /// learning what's usual here.
    case watching
    /// The camera is on for a moment, looking for a second face.
    case checking
    /// Someone's nearby. Do Not Disturb is on if the guard could turn it on
    /// (see `PresenceGuard.turnedFocusOn`).
    case guarding
}

// MARK: - Adapters

protocol ProximityScanning: AnyObject {
    /// Whether advertisements are actually arriving (Bluetooth on and allowed).
    var onSensingChange: (@MainActor @Sendable (Bool) -> Void)? { get set }
    func start()
    func stop()
    func setThreshold(_ dBm: Double)
    func nearCount(at now: Date) -> Int
}

protocol FaceChecking: AnyObject {
    var isAuthorized: Bool { get }
    /// `completion` isn't called after `cancel()`.
    func start(completion: @escaping @MainActor @Sendable (FaceCheckResult) -> Void)
    func cancel()
}

protocol FocusControlling: Sendable {
    func setFocus(_ on: Bool) async -> Bool
    func installedShortcuts() async -> Set<FocusShortcut>?
}

@MainActor
protocol UserActivityMonitoring: AnyObject {
    var isActive: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

struct ShortcutsFocusController: FocusControlling {
    func setFocus(_ on: Bool) async -> Bool {
        await NotchHelperClient.shared.runFocusShortcut(on ? .on : .off)
    }

    func installedShortcuts() async -> Set<FocusShortcut>? {
        await NotchHelperClient.shared.installedFocusShortcuts()
    }
}

// MARK: - Guard

@MainActor
final class PresenceGuard: ObservableObject {
    static let shared = PresenceGuard(
        scanner: BluetoothProximityScanner(),
        faceChecker: CameraFaceChecker(),
        focus: ShortcutsFocusController(),
        activity: UserActivityMonitor()
    )

    /// How often the near count is read while scanning.
    static let tickInterval: TimeInterval = 2

    @Published private(set) var state: PresenceGuardState = .off
    /// Focus is on because the guard turned it on.
    @Published private(set) var turnedFocusOn: Bool
    /// Personal Apple devices close by right now.
    @Published private(set) var nearCount = 0
    /// How many is usual here; nil while still learning.
    @Published private(set) var usualCount: Int?
    /// Which Focus shortcuts exist; nil if unknown.
    @Published private(set) var installedShortcuts: Set<FocusShortcut>?
    @Published private(set) var isCheckingShortcuts = false

    private var machine: PresenceGuardMachine
    private let scanner: ProximityScanning
    private let faceChecker: FaceChecking
    private let focus: FocusControlling
    private let activity: UserActivityMonitoring
    private let now: () -> Date
    private let persistFocusFlag: (Bool) -> Void
    /// Whether another feature has the camera. Set by `start`.
    var isCameraBusy: @MainActor () -> Bool = { false }
    private let schedulesTicks: Bool
    private var timer: Timer?
    /// Bumped per camera check, so a late answer from a cancelled one is ignored.
    private var checkGeneration = 0
    /// Focus commands run one after another, never overlapping.
    private var focusCommands: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    init(
        scanner: ProximityScanning,
        faceChecker: FaceChecking,
        focus: FocusControlling,
        activity: UserActivityMonitoring,
        focusOnByGuard: Bool = Defaults[.presenceGuardTurnedFocusOn],
        schedulesTicks: Bool = true,
        now: @escaping () -> Date = Date.init,
        persistFocusFlag: @escaping (Bool) -> Void = { Defaults[.presenceGuardTurnedFocusOn] = $0 }
    ) {
        self.scanner = scanner
        self.faceChecker = faceChecker
        self.focus = focus
        self.activity = activity
        self.schedulesTicks = schedulesTicks
        self.now = now
        self.persistFocusFlag = persistFocusFlag
        machine = PresenceGuardMachine(focusOnByGuard: focusOnByGuard)
        turnedFocusOn = focusOnByGuard

        scanner.onSensingChange = { [weak self] sensing in
            guard let self else { return }
            self.apply(self.machine.setSensing(sensing, at: self.now()))
        }
        activity.onChange = { [weak self] active in
            guard let self else { return }
            self.apply(self.machine.setUserActive(active, at: self.now()))
        }
    }

    /// Follows the settings from here on. `isCameraBusy` says whether another
    /// feature (the mirror) has the camera; the guard waits for it.
    func start(isCameraBusy: @escaping @MainActor () -> Bool) {
        guard settingsTask == nil else { return }
        // Tests drive their own instances; the test host never listens.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        self.isCameraBusy = isCameraBusy
        settingsTask = Task { @MainActor [weak self] in
            // Alert mode (the header's shield button) is the only switch.
            for await (alertMode, sensitivity) in Defaults.updates(.alertMode, .presenceSensitivity) {
                guard let self else { return }
                self.setSensitivity(sensitivity)
                self.update(enabled: true, alertMode: alertMode)
            }
        }
    }

    func update(enabled: Bool, alertMode: Bool) {
        if enabled && alertMode {
            activity.start()
            apply(machine.setUserActive(activity.isActive, at: now()))
            apply(machine.activate(at: now()))
        } else {
            apply(machine.deactivate(at: now()))
            activity.stop()
        }
    }

    func setSensitivity(_ sensitivity: PresenceSensitivity) {
        scanner.setThreshold(sensitivity.threshold)
    }

    /// "I'm alone now": forget what was usual and learn it again.
    func recalibrate() {
        apply(machine.recalibrate(at: now()))
    }

    func refreshShortcuts() async {
        isCheckingShortcuts = true
        installedShortcuts = await focus.installedShortcuts()
        isCheckingShortcuts = false
    }

    /// For tests: waits until every Focus command sent so far has finished.
    func waitForFocusCommands() async {
        await focusCommands?.value
    }

    // MARK: - Ticks

    func tick() {
        let now = now()
        let count = scanner.nearCount(at: now)
        if nearCount != count { nearCount = count }
        let cameraAvailable = faceChecker.isAuthorized && !isCameraBusy()
        apply(machine.tick(nearCount: count, cameraAvailable: cameraAvailable, at: now))
    }

    private func startTicking() {
        guard schedulesTicks, timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        nearCount = 0
    }

    // MARK: - Effects

    private func apply(_ effects: [PresenceGuardMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startScanning:
                scanner.start()
                startTicking()
            case .stopScanning:
                scanner.stop()
                stopTicking()
            case .startFaceCheck:
                checkGeneration += 1
                let generation = checkGeneration
                faceChecker.start { [weak self] result in
                    guard let self, generation == self.checkGeneration else { return }
                    Log.presence.info("Camera check: \(String(describing: result), privacy: .public)")
                    self.apply(self.machine.faceCheckFinished(result, at: self.now()))
                }
            case .cancelFaceCheck:
                checkGeneration += 1
                faceChecker.cancel()
            case .setFocus(let on):
                setFocus(on)
            }
        }
        publish()
    }

    private func setFocus(_ on: Bool) {
        let previous = focusCommands
        focusCommands = Task { [weak self, focus] in
            await previous?.value
            let succeeded = await focus.setFocus(on)
            guard let self else { return }
            if succeeded {
                Log.presence.notice("Focus turned \(on ? "on" : "off", privacy: .public)")
            } else {
                Log.presence.notice("Focus shortcut failed (turning \(on ? "on" : "off", privacy: .public))")
                self.machine.focusCommandFailed(turningOn: on, at: self.now())
                self.publish()
            }
        }
    }

    private func publish() {
        let newState: PresenceGuardState
        if !machine.isOn {
            newState = .off
        } else {
            switch machine.phase {
            case .inactive: newState = .paused
            case .settling, .idle, .suspicious: newState = .watching
            case .checking: newState = .checking
            case .guarding, .clearing: newState = .guarding
            }
        }
        if state != newState {
            Log.presence.info("Presence guard: \(String(describing: newState), privacy: .public)")
            state = newState
        }
        if turnedFocusOn != machine.focusOnByGuard {
            turnedFocusOn = machine.focusOnByGuard
            persistFocusFlag(machine.focusOnByGuard)
        }
        let usual = machine.usualCount(at: now())
        if usualCount != usual { usualCount = usual }
    }
}
