//
//  FaceUnlockRetryShortcut.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  After a lock-screen scan gives up, double-tapping a modifier key (Right
//  Shift by default) scans again — like raising an iPhone to retry Face ID.
//  Only lone modifiers are offered: anything else would type into the lock
//  screen's password field, and a modifier on its own types nothing.
//
//  The key is read by polling the HID modifier flags while the screen is
//  locked and face unlock is idle. The lock screen's secure input blinds event
//  taps and per-key state, but the flags (with their left/right bits) still
//  update.
//

import CoreGraphics
import Defaults
import Foundation
import QuartzCore

enum FaceUnlockRetryKey: String, CaseIterable, Codable {
    case off
    case rightShift, leftShift
    case rightOption, leftOption
    case rightCommand, leftCommand
    case control

    var label: String {
        switch self {
        case .off: return "Off"
        case .rightShift: return "Double-tap Right Shift"
        case .leftShift: return "Double-tap Left Shift"
        case .rightOption: return "Double-tap Right Option"
        case .leftOption: return "Double-tap Left Option"
        case .rightCommand: return "Double-tap Right Command"
        case .leftCommand: return "Double-tap Left Command"
        case .control: return "Double-tap Control"
        }
    }

    /// Device-dependent (left/right) modifier bits of CGEventFlags, from
    /// IOLLEvent.h's NX_DEVICE*KEYMASK. Control covers both sides, since laptop
    /// keyboards only have a left one. Read from the modifier flags because at
    /// the lock screen secure input makes per-key state (keyState) always read
    /// "up", while the flags still change (confirmed on the real lock screen).
    var deviceMask: UInt64 {
        switch self {
        case .off: return 0
        case .rightShift: return 0x04
        case .leftShift: return 0x02
        case .rightOption: return 0x40
        case .leftOption: return 0x20
        case .rightCommand: return 0x10
        case .leftCommand: return 0x08
        case .control: return 0x01 | 0x2000
        }
    }

    /// Every modifier's device bit, to tell a lone tap from part of a chord.
    static let allDeviceMasks: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000
}

extension FaceUnlockRetryKey: Defaults.Serializable {}

/// Pure double-tap logic, separated for testing. Feed it the watched key's
/// state on every poll; it reports true once per completed double tap.
struct DoubleTapDetector {
    /// A press held longer than this isn't a tap.
    var maxTapDuration: TimeInterval = 0.35
    /// The second press must start within this long after the first release.
    var maxGap: TimeInterval = 0.45

    private var isDown = false
    private var downAt: TimeInterval = 0
    private var pressInvolvedOtherKeys = false
    private var lastTapReleasedAt: TimeInterval?

    mutating func update(keyDown: Bool, otherModifiersDown: Bool, at time: TimeInterval) -> Bool {
        if otherModifiersDown {
            // Part of a chord (e.g. Shift+Command): never counts, and breaks a pending double.
            pressInvolvedOtherKeys = pressInvolvedOtherKeys || isDown || keyDown
            lastTapReleasedAt = nil
        }
        defer { isDown = keyDown }

        if keyDown, !isDown {                       // pressed
            downAt = time
            pressInvolvedOtherKeys = otherModifiersDown
            if let last = lastTapReleasedAt, time - last > maxGap { lastTapReleasedAt = nil }
            return false
        }
        guard !keyDown, isDown else { return false }  // only a release can complete a tap

        let wasTap = !pressInvolvedOtherKeys && time - downAt <= maxTapDuration
        guard wasTap else { lastTapReleasedAt = nil; return false }
        if let last = lastTapReleasedAt, downAt - last <= maxGap {
            lastTapReleasedAt = nil
            return true
        }
        lastTapReleasedAt = time
        return false
    }
}

/// Watches the keyboard and trackpad while the screen is locked and on: a
/// double tap of the chosen key calls `onTrigger`, and any input at all calls
/// `onInput` (how the manager tells the user has come back). Both read HID
/// state, which the lock screen's secure input doesn't hide.
@MainActor
final class FaceUnlockRetryShortcutMonitor {
    var onTrigger: (() -> Void)?
    var onInput: (() -> Void)?

    private var timer: Timer?
    private var detector = DoubleTapDetector()
    private var key: FaceUnlockRetryKey = .off
    /// Keeps App Nap from throttling the poll while the app sits behind the
    /// lock screen; held only while armed.
    private var activity: NSObjectProtocol?

    private var wasDown = false
    private var lastIdle: CFTimeInterval = .infinity
    /// kCGAnyInputEventType: keys, clicks, scrolls and pointer movement.
    private let anyInput = CGEventType(rawValue: ~0)!

    var isRunning: Bool { timer != nil }

    /// `key` may be `.off`: input is still reported, just no double tap.
    func start(key: FaceUnlockRetryKey) {
        stop()
        self.key = key
        detector = DoubleTapDetector()
        wasDown = false
        lastIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Face Unlock retry shortcut")
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.faceUnlock.notice("input watch on (key: \(key.rawValue, privacy: .public))")
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Log.faceUnlock.notice("input watch off")
    }

    private func poll() {
        // The idle time only goes down when a new input event arrives.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        if idle < lastIdle { onInput?() }
        lastIdle = idle

        guard key != .off else { return }
        let flags = CGEventSource.flagsState(.hidSystemState).rawValue
        let down = flags & key.deviceMask != 0
        let others = flags & (FaceUnlockRetryKey.allDeviceMasks & ~key.deviceMask) != 0
        if down != wasDown {
            Log.faceUnlock.debug("retry key \(down ? "down" : "up", privacy: .public)")
            wasDown = down
        }
        if detector.update(keyDown: down, otherModifiersDown: others, at: CACurrentMediaTime()) {
            Log.faceUnlock.notice("retry shortcut double-tapped")
            onTrigger?()
        }
    }
}
