//
//  PresenceGuardMachine.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The presence guard's decisions, with no Bluetooth, camera or Shortcuts in
//  sight: it's fed the near-device count every couple of seconds, plus what
//  the user and the adapters are doing, and answers with effects for
//  PresenceGuard to carry out.
//
//    idle → suspicious → checking → guarding → clearing → idle
//
//  Suspicious: more devices close by than usual, for a few seconds.
//  Checking: the camera looks for a second face. Guarding: it saw one, and
//  Focus is on. Clearing: the count is back to usual; Focus goes off if it
//  stays there. Your own phone, watch and AirPods advertise too and can't be
//  told apart from anyone else's, so "usual" is learned (PresenceBaseline).
//

import Foundation

/// What a camera check concluded.
enum FaceCheckResult: Equatable {
    /// Two or more faces, in more than one frame.
    case confirmed
    /// Enough frames, never two faces in enough of them.
    case alone
    /// No answer: no access, the camera is busy, or it gave too few frames.
    case unavailable
}

/// The near-device count you're usually at, learned while nothing's going on.
///
/// Fresh sessions start by calibrating: the highest count over the first few
/// seconds, on the assumption that whoever turned the guard on is alone and
/// everything around is theirs or part of the room. After that it's the
/// upper quartile of the count over the last ten minutes. The upper quartile
/// rather than the minimum so a phone that's only heard some of the time —
/// locked, in a pocket — still counts as yours; and only counts sampled while
/// idle feed it, so a visitor the guard noticed never becomes "usual".
struct PresenceBaseline {
    var window: TimeInterval = 10 * 60
    var percentile = 0.75
    var calibrationDuration: TimeInterval = 10
    /// Fewer samples than this and the calibrated value stands.
    var minimumSamples = 15

    private(set) var value: Int?
    private var samples: [(date: Date, count: Int)] = []
    private var calibration: (start: Date, peak: Int)?

    var isCalibrating: Bool { calibration != nil }
    var isLearning: Bool { value == nil }

    mutating func startCalibration(at now: Date) {
        samples.removeAll()
        value = nil
        calibration = (now, 0)
    }

    mutating func record(_ count: Int, at now: Date) {
        if let calibration {
            let peak = max(calibration.peak, count)
            if now.timeIntervalSince(calibration.start) >= calibrationDuration {
                value = peak
                self.calibration = nil
            } else {
                self.calibration = (calibration.start, peak)
            }
            return
        }
        samples.removeAll { now.timeIntervalSince($0.date) > window }
        samples.append((now, count))
        if samples.count >= minimumSamples {
            value = Self.percentile(samples.map(\.count), percentile)
        }
    }

    /// Nearest-rank percentile; nil for no values.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

struct PresenceGuardMachine {
    struct Timing {
        /// After scanning starts, before counts mean anything.
        var settle: TimeInterval = 6
        /// How long the count has to stay above usual before the camera looks.
        var suspicion: TimeInterval = 6
        /// How long it has to stay back at usual before Focus goes off.
        var clear: TimeInterval = 30
        /// Between camera checks, at most one per this.
        var minimumCheckInterval: TimeInterval = 60
        /// After a check that couldn't run (camera busy, say), try again after this.
        var unavailableRetry: TimeInterval = 15
        /// After a check found you alone, that count counts as alone for this
        /// long: no more checks unless more devices turn up.
        var aloneLifetime: TimeInterval = 10 * 60
        /// A check that never answers is given up on after this.
        var checkTimeout: TimeInterval = 10
        /// After Focus failed to turn off, try again after this.
        var focusRetry: TimeInterval = 60
    }

    enum Phase: Equatable {
        /// Off, paused, or waiting on Bluetooth.
        case inactive
        case settling(until: Date)
        case idle
        case suspicious(since: Date)
        /// `count` is the near count the check was started at.
        case checking(since: Date, count: Int)
        case guarding
        case clearing(since: Date)
    }

    enum Effect: Equatable {
        case startScanning
        case stopScanning
        case startFaceCheck
        case cancelFaceCheck
        case setFocus(Bool)
    }

    var timing = Timing()
    private(set) var phase: Phase = .inactive
    /// Focus is on because of the guard. Persisted by the owner, so a quit
    /// mid-guard still gets cleaned up.
    private(set) var focusOnByGuard: Bool
    private(set) var baseline = PresenceBaseline()
    /// Alert mode on (and the feature enabled).
    private(set) var isOn = false
    private(set) var isUserActive = false
    /// The scanner is actually hearing advertisements.
    private(set) var isSensing = false
    private var isScanning = false
    private var nextCheckAt: Date?
    /// A count a camera check found you alone at.
    private var alone: (count: Int, until: Date)?
    private var nextFocusRetryAt: Date?

    init(focusOnByGuard: Bool = false) {
        self.focusOnByGuard = focusOnByGuard
    }

    // MARK: - Inputs

    /// Alert mode turned on: a new situation, so the baseline is learned
    /// fresh. Focus left on by an earlier run (the app quit mid-guard) goes
    /// off first.
    mutating func activate(at now: Date) -> [Effect] {
        guard !isOn else { return [] }
        isOn = true
        baseline = PresenceBaseline()
        alone = nil
        nextCheckAt = nil
        var effects = turnFocusOffIfOurs()
        effects += reconcile(at: now)
        return effects
    }

    /// Alert mode off, or the feature disabled: everything stops, and Focus
    /// goes off if the guard turned it on.
    mutating func deactivate(at now: Date) -> [Effect] {
        isOn = false
        var effects = turnFocusOffIfOurs()
        effects += reconcile(at: now)
        baseline = PresenceBaseline()
        alone = nil
        nextCheckAt = nil
        return effects
    }

    /// Away, locked or asleep pauses everything but leaves Focus as it is;
    /// coming back re-evaluates it.
    mutating func setUserActive(_ active: Bool, at now: Date) -> [Effect] {
        isUserActive = active
        return reconcile(at: now)
    }

    mutating func setSensing(_ sensing: Bool, at now: Date) -> [Effect] {
        isSensing = sensing
        return reconcile(at: now)
    }

    /// "I'm alone now": learn the baseline again, and stand down.
    mutating func recalibrate(at now: Date) -> [Effect] {
        baseline = PresenceBaseline()
        alone = nil
        var effects: [Effect] = []
        switch phase {
        case .checking:
            effects.append(.cancelFaceCheck)
            phase = .idle
        case .suspicious, .guarding, .clearing:
            phase = .idle
        case .inactive, .settling, .idle:
            break
        }
        effects += turnFocusOffIfOurs()
        return effects
    }

    mutating func tick(nearCount count: Int, cameraAvailable: Bool, at now: Date) -> [Effect] {
        switch phase {
        case .inactive:
            return []

        case .settling(let until):
            guard now >= until else { return [] }
            phase = focusOnByGuard ? .guarding : .idle
            return tick(nearCount: count, cameraAvailable: cameraAvailable, at: now)

        case .idle:
            let effects = retryFocusOffIfDue(at: now)
            if baseline.isLearning && !baseline.isCalibrating {
                baseline.startCalibration(at: now)
            }
            if let usual = usualCount(at: now), count > usual {
                phase = .suspicious(since: now)
            } else {
                baseline.record(count, at: now)
            }
            return effects

        case .suspicious(let since):
            guard let usual = usualCount(at: now), count > usual else {
                phase = .idle
                return tick(nearCount: count, cameraAvailable: cameraAvailable, at: now)
            }
            guard now.timeIntervalSince(since) >= timing.suspicion,
                  cameraAvailable,
                  nextCheckAt.map({ now >= $0 }) ?? true
            else { return [] }
            phase = .checking(since: now, count: count)
            nextCheckAt = now.addingTimeInterval(timing.minimumCheckInterval)
            return [.startFaceCheck]

        case .checking(let since, _):
            // The mirror opened mid-check, or the check never answered.
            if !cameraAvailable || now.timeIntervalSince(since) >= timing.checkTimeout {
                phase = .suspicious(since: .distantPast)
                nextCheckAt = now.addingTimeInterval(timing.unavailableRetry)
                return [.cancelFaceCheck]
            }
            return []

        case .guarding:
            if let usual = usualCount(at: now), count <= usual {
                phase = .clearing(since: now)
            }
            return []

        case .clearing(let since):
            guard let usual = usualCount(at: now), count <= usual else {
                phase = .guarding
                return []
            }
            guard now.timeIntervalSince(since) >= timing.clear else { return [] }
            phase = .idle
            return turnFocusOffIfOurs()
        }
    }

    mutating func faceCheckFinished(_ result: FaceCheckResult, at now: Date) -> [Effect] {
        guard case .checking(_, let count) = phase else { return [] }
        switch result {
        case .confirmed:
            phase = .guarding
            guard !focusOnByGuard else { return [] }
            focusOnByGuard = true
            return [.setFocus(true)]
        case .alone:
            let previous = alone.flatMap { now < $0.until ? $0.count : nil } ?? 0
            alone = (max(previous, count), now.addingTimeInterval(timing.aloneLifetime))
            phase = .idle
            return []
        case .unavailable:
            phase = .suspicious(since: .distantPast)
            nextCheckAt = now.addingTimeInterval(timing.unavailableRetry)
            return []
        }
    }

    /// The Shortcut for `turningOn` didn't run.
    mutating func focusCommandFailed(turningOn: Bool, at now: Date) {
        if turningOn {
            // It never came on, so it's not ours to turn off.
            focusOnByGuard = false
        } else {
            focusOnByGuard = true
            nextFocusRetryAt = now.addingTimeInterval(timing.focusRetry)
        }
    }

    // MARK: - Helpers

    /// The count above which someone else is plausibly here: the baseline, or
    /// a count a camera check found you alone at. Nil while still learning.
    /// While guarding, the alone count holds until the visitor's gone.
    func usualCount(at now: Date) -> Int? {
        guard let usual = baseline.value else { return nil }
        guard let alone else { return usual }
        switch phase {
        case .guarding, .clearing:
            return max(usual, alone.count)
        default:
            return now < alone.until ? max(usual, alone.count) : usual
        }
    }

    private mutating func reconcile(at now: Date) -> [Effect] {
        var effects: [Effect] = []
        let wantsScanning = isOn && isUserActive
        let running = wantsScanning && isSensing

        if !running, phase != .inactive {
            if case .checking = phase { effects.append(.cancelFaceCheck) }
            phase = .inactive
        }
        if wantsScanning != isScanning {
            isScanning = wantsScanning
            effects.append(wantsScanning ? .startScanning : .stopScanning)
        }
        if running, phase == .inactive {
            phase = .settling(until: now.addingTimeInterval(timing.settle))
        }
        return effects
    }

    private mutating func turnFocusOffIfOurs() -> [Effect] {
        guard focusOnByGuard else { return [] }
        focusOnByGuard = false
        nextFocusRetryAt = nil
        return [.setFocus(false)]
    }

    private mutating func retryFocusOffIfDue(at now: Date) -> [Effect] {
        guard focusOnByGuard, let retryAt = nextFocusRetryAt, now >= retryAt else { return [] }
        return turnFocusOffIfOurs()
    }
}
