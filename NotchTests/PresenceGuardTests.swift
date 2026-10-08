//
//  PresenceGuardTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Alert mode's presence guard: reading Continuity advertisements, smoothing
//  and expiring signal readings, learning what's usual, when the camera is
//  asked to look, rate limits, only turning off a Focus it turned on, and
//  pausing while the user is away. Everything runs on fakes — no Bluetooth,
//  camera or Shortcuts.
//

import XCTest
@testable import Notch

// MARK: - Continuity advertisements

final class ContinuityAdvertisementTests: XCTestCase {
    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    func testNearbyInfoIsAPersonalDevice() throws {
        let ad = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x10, 0x05, 0x01, 0x18, 0x1C, 0x4E, 0x2F])))
        XCTAssertEqual(ad.messages.count, 1)
        XCTAssertEqual(ad.messages[0].type, 0x10)
        XCTAssertEqual(ad.messages[0].payload, data([0x01, 0x18, 0x1C, 0x4E, 0x2F]))
        XCTAssertEqual(ad.kind, .personal)
    }

    func testProximityPairingIsAudio() throws {
        // AirPods Pro: 25-byte proximity pairing payload.
        let payload: [UInt8] = [0x01, 0x0E, 0x20] + Array(repeating: 0xAB, count: 22)
        let ad = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x07, 0x19] + payload)))
        XCTAssertEqual(ad.kind, .audio)
    }

    func testSeveralMessagesInOneAdvertisement() throws {
        let handoff: [UInt8] = [0x0C, 0x0E] + Array(repeating: 0x11, count: 14)
        let nearby: [UInt8] = [0x10, 0x05, 0x01, 0x18, 0x1C, 0x4E, 0x2F]
        let ad = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00] + handoff + nearby)))
        XCTAssertEqual(ad.messages.map(\.type), [0x0C, 0x10])
        XCTAssertTrue(ad.contains(.handoff))
        XCTAssertTrue(ad.contains(.nearbyInfo))
        XCTAssertEqual(ad.kind, .personal)
    }

    func testThingsPeopleDontCarryArentCounted() throws {
        let beacon = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x02, 0x15] + Array(repeating: 0, count: 21))))
        XCTAssertNil(beacon.kind)
        let findMy = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x12, 0x02, 0x00, 0x01])))
        XCTAssertNil(findMy.kind)
        let airPlay = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x09, 0x02, 0x00, 0x01])))
        XCTAssertNil(airPlay.kind)
    }

    func testOtherCompaniesAreIgnored() {
        // Microsoft's company ID, with a Nearby Info-shaped body.
        XCTAssertNil(ContinuityAdvertisement(manufacturerData: data([0x06, 0x00, 0x10, 0x02, 0x01, 0x02])))
    }

    func testTruncatedDataIsRejected() {
        XCTAssertNil(ContinuityAdvertisement(manufacturerData: Data()))
        XCTAssertNil(ContinuityAdvertisement(manufacturerData: data([0x4C])))
        XCTAssertNil(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x10])))
        // Says five bytes, has two.
        XCTAssertNil(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x10, 0x05, 0x01, 0x18])))
    }

    func testATruncatedSecondMessageKeepsTheFirst() throws {
        let ad = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: data([0x4C, 0x00, 0x10, 0x02, 0x01, 0x18, 0x07, 0x19, 0x01])))
        XCTAssertEqual(ad.messages.map(\.type), [0x10])
        XCTAssertEqual(ad.kind, .personal)
    }

    func testDataFromASliceParses() throws {
        // CoreBluetooth hands over Data that isn't always zero-based.
        let whole = data([0xFF, 0xFF, 0x4C, 0x00, 0x10, 0x02, 0x01, 0x18])
        let ad = try XCTUnwrap(ContinuityAdvertisement(manufacturerData: whole.dropFirst(2)))
        XCTAssertEqual(ad.kind, .personal)
    }

    func testRandomBytesNeverCrashOrRunAway() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...40, using: &generator)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if bytes.count >= 2 { bytes[0] = 0x4C; bytes[1] = 0x00 }
            if let ad = ContinuityAdvertisement(manufacturerData: Data(bytes)) {
                XCTAssertLessThanOrEqual(ad.messages.count, 8)
                XCTAssertLessThanOrEqual(ad.messages.reduce(0) { $0 + $1.payload.count + 2 }, bytes.count - 2)
            }
        }
    }
}

/// Deterministic randomness for the fuzz test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Proximity tracking

final class ProximityTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let phone = UUID()
    private let watch = UUID()

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Heard every `interval` seconds from `from` to `to`.
    private func hear(_ tracker: inout ProximityTracker, _ id: UUID, rssi: Int, from: TimeInterval, to: TimeInterval,
                      every interval: TimeInterval = 0.5, kind: ContinuityAdvertisement.Kind = .personal) {
        var time = from
        while time <= to + 0.0001 {
            tracker.observe(id, kind: kind, rssi: rssi, at: at(time))
            time += interval
        }
    }

    func testSmoothingFollowsReadingsOverTime() throws {
        var tracker = ProximityTracker()
        tracker.observe(phone, kind: .personal, rssi: -70, at: at(0))
        tracker.observe(phone, kind: .personal, rssi: -50, at: at(2))
        // One time constant: about 63% of the way.
        let rssi = try XCTUnwrap(tracker.entries[phone]?.rssi)
        XCTAssertEqual(rssi, -70 + (1 - exp(-1)) * 20, accuracy: 0.001)
    }

    func testOneStrongPacketBarelyMovesASmoothedDevice() throws {
        var tracker = ProximityTracker()
        hear(&tracker, phone, rssi: -80, from: 0, to: 5)
        tracker.observe(phone, kind: .personal, rssi: -40, at: at(5.1))
        let rssi = try XCTUnwrap(tracker.entries[phone]?.rssi)
        XCTAssertLessThan(rssi, -77)
    }

    func testMissingReadingsAreIgnored() {
        var tracker = ProximityTracker()
        tracker.observe(phone, kind: .personal, rssi: 127, at: at(0))
        tracker.observe(phone, kind: .personal, rssi: 0, at: at(0))
        XCTAssertTrue(tracker.entries.isEmpty)
    }

    func testADeviceCountsOnlyAfterItsBeenHeardAWhile() {
        var tracker = ProximityTracker()
        hear(&tracker, phone, rssi: -50, from: 0, to: 1.5)
        XCTAssertEqual(tracker.nearCount(at: at(1.5)), 0)
        hear(&tracker, phone, rssi: -50, from: 2, to: 2)
        XCTAssertEqual(tracker.nearCount(at: at(2)), 1)
    }

    func testAQuietDeviceStopsCountingThenIsForgotten() {
        var tracker = ProximityTracker()
        hear(&tracker, phone, rssi: -50, from: 0, to: 3)
        XCTAssertEqual(tracker.nearCount(at: at(8)), 1)
        XCTAssertEqual(tracker.nearCount(at: at(8.1)), 0)
        tracker.prune(at: at(12.9))
        XCTAssertNotNil(tracker.entries[phone])
        tracker.prune(at: at(13.1))
        XCTAssertNil(tracker.entries[phone])
    }

    func testThresholdHasHysteresis() {
        var tracker = ProximityTracker()
        tracker.threshold = -65
        tracker.smoothing = 0.001  // follow readings exactly
        hear(&tracker, phone, rssi: -60, from: 0, to: 3)
        XCTAssertEqual(tracker.nearCount(at: at(3)), 1)
        hear(&tracker, phone, rssi: -68, from: 3.5, to: 5)
        XCTAssertEqual(tracker.nearCount(at: at(5)), 1, "still within the hysteresis band")
        hear(&tracker, phone, rssi: -71, from: 5.5, to: 6)
        XCTAssertEqual(tracker.nearCount(at: at(6)), 0)
        hear(&tracker, phone, rssi: -67, from: 6.5, to: 8)
        XCTAssertEqual(tracker.nearCount(at: at(8)), 0, "has to reach the threshold again")
        hear(&tracker, phone, rssi: -64, from: 8.5, to: 9)
        XCTAssertEqual(tracker.nearCount(at: at(9)), 1)
    }

    func testFarDevicesDontCount() {
        var tracker = ProximityTracker()
        tracker.threshold = PresenceSensitivity.low.threshold
        hear(&tracker, phone, rssi: -62, from: 0, to: 4)
        XCTAssertEqual(tracker.nearCount(at: at(4)), 0)
        tracker.threshold = PresenceSensitivity.high.threshold
        hear(&tracker, watch, rssi: -62, from: 0, to: 4)
        XCTAssertEqual(tracker.nearCount(at: at(4)), 1)
    }

    func testAnAddressRotationCountsOnce() {
        var tracker = ProximityTracker()
        let rotated = UUID()
        hear(&tracker, phone, rssi: -55, from: 0, to: 10)
        hear(&tracker, rotated, rssi: -56, from: 10.3, to: 14)
        // The old address is still fresh for a few seconds after it stops.
        XCTAssertEqual(tracker.nearCount(at: at(12.5)), 1)
        XCTAssertEqual(tracker.nearCount(at: at(14)), 1)
    }

    func testTwoDevicesHeardTogetherCountTwice() {
        var tracker = ProximityTracker()
        hear(&tracker, phone, rssi: -55, from: 0, to: 10)
        hear(&tracker, watch, rssi: -56, from: 6, to: 10)
        XCTAssertEqual(tracker.nearCount(at: at(10)), 2)
    }

    func testANewcomerUnlikeTheQuietDeviceIsntMistakenForIt() {
        var tracker = ProximityTracker()
        tracker.threshold = -70
        let stranger = UUID()
        hear(&tracker, phone, rssi: -45, from: 0, to: 10)
        hear(&tracker, stranger, rssi: -66, from: 10.3, to: 13)
        XCTAssertEqual(tracker.nearCount(at: at(13)), 2, "too different in strength to be the same device")
        let earbuds = UUID()
        hear(&tracker, earbuds, rssi: -45, from: 10.3, to: 13, kind: .audio)
        XCTAssertEqual(tracker.nearCount(at: at(13)), 3, "a different kind of device")
    }

    func testMemoryIsBounded() {
        var tracker = ProximityTracker()
        tracker.capacity = 50
        for index in 0..<200 {
            tracker.observe(UUID(), kind: .personal, rssi: -60, at: at(Double(index) * 0.01))
        }
        XCTAssertLessThanOrEqual(tracker.entries.count, 50)
    }
}

// MARK: - Baseline

final class PresenceBaselineTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testCalibrationTakesThePeak() {
        var baseline = PresenceBaseline()
        baseline.startCalibration(at: at(0))
        baseline.record(1, at: at(0))
        baseline.record(2, at: at(4))
        baseline.record(1, at: at(8))
        XCTAssertNil(baseline.value)
        XCTAssertTrue(baseline.isCalibrating)
        baseline.record(1, at: at(10))
        XCTAssertEqual(baseline.value, 2)
        XCTAssertFalse(baseline.isCalibrating)
    }

    func testUpperQuartileOnceThereAreEnoughSamples() {
        var baseline = PresenceBaseline()
        baseline.startCalibration(at: at(0))
        baseline.record(3, at: at(10))
        XCTAssertEqual(baseline.value, 3)
        // Too few samples: the calibration stands.
        for index in 0..<10 { baseline.record(1, at: at(12 + Double(index) * 2)) }
        XCTAssertEqual(baseline.value, 3)
        for index in 10..<20 { baseline.record(1, at: at(12 + Double(index) * 2)) }
        XCTAssertEqual(baseline.value, 1)
    }

    func testAPhoneHeardSomeOfTheTimeStillCountsAsYours() {
        var baseline = PresenceBaseline()
        baseline.startCalibration(at: at(0))
        baseline.record(1, at: at(10))
        // Seen 35% of the time.
        for index in 0..<100 {
            baseline.record(index % 20 < 7 ? 2 : 1, at: at(12 + Double(index) * 2))
        }
        XCTAssertEqual(baseline.value, 2)
    }

    func testOldSamplesAgeOut() {
        var baseline = PresenceBaseline()
        baseline.startCalibration(at: at(0))
        baseline.record(3, at: at(10))
        for index in 0..<100 { baseline.record(3, at: at(12 + Double(index) * 2)) }
        XCTAssertEqual(baseline.value, 3)
        // Eleven minutes later, at one device.
        for index in 0..<330 { baseline.record(1, at: at(212 + Double(index) * 2)) }
        XCTAssertEqual(baseline.value, 1)
    }

    func testPercentile() {
        XCTAssertNil(PresenceBaseline.percentile([], 0.75))
        XCTAssertEqual(PresenceBaseline.percentile([5], 0.75), 5)
        XCTAssertEqual(PresenceBaseline.percentile([4, 1, 3, 2], 0.75), 3)
        XCTAssertEqual(PresenceBaseline.percentile([1, 2, 3, 4], 0), 1)
        XCTAssertEqual(PresenceBaseline.percentile([1, 2, 3, 4], 1), 4)
    }
}

// MARK: - State machine

final class PresenceGuardMachineTests: XCTestCase {
    private typealias Effect = PresenceGuardMachine.Effect

    private var machine = PresenceGuardMachine()
    private var now = Date(timeIntervalSinceReferenceDate: 0)

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    @discardableResult
    private func tick(_ count: Int, camera: Bool = true) -> [Effect] {
        machine.tick(nearCount: count, cameraAvailable: camera, at: now)
    }

    /// Ticks every two seconds for `seconds`, collecting effects.
    @discardableResult
    private func hold(_ count: Int, for seconds: TimeInterval, camera: Bool = true) -> [Effect] {
        var effects: [Effect] = []
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            advance(2)
            elapsed += 2
            effects += tick(count, camera: camera)
        }
        return effects
    }

    /// Alert mode on, user active, Bluetooth hearing, settled, and the
    /// baseline calibrated at `usual`.
    private func startWatching(usual: Int = 2) {
        _ = machine.setUserActive(true, at: now)
        XCTAssertEqual(machine.activate(at: now), [.startScanning])
        _ = machine.setSensing(true, at: now)
        hold(usual, for: 18)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.usualCount(at: now), usual)
    }

    /// From watching at `usual`, a visitor the camera confirms.
    private func startGuarding(usual: Int = 2) {
        startWatching(usual: usual)
        XCTAssertEqual(hold(usual + 1, for: 8), [.startFaceCheck])
        XCTAssertEqual(machine.faceCheckFinished(.confirmed, at: now), [.setFocus(true)])
        XCTAssertEqual(machine.phase, .guarding)
    }

    // MARK: Starting and stopping

    func testNothingRunsUntilAlertModeIsOn() {
        XCTAssertEqual(machine.setUserActive(true, at: now), [])
        XCTAssertEqual(machine.setSensing(true, at: now), [])
        XCTAssertEqual(tick(5), [])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testCountsAreIgnoredWhileSettling() {
        _ = machine.setUserActive(true, at: now)
        XCTAssertEqual(machine.activate(at: now), [.startScanning])
        XCTAssertEqual(machine.phase, .inactive, "waiting for Bluetooth")
        _ = machine.setSensing(true, at: now)
        XCTAssertEqual(machine.phase, .settling(until: now.addingTimeInterval(6)))
        advance(4)
        tick(9)
        XCTAssertEqual(machine.phase, .settling(until: now.addingTimeInterval(2)))
        advance(2)
        tick(2)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testCalibrationNeverTriggers() {
        _ = machine.setUserActive(true, at: now)
        _ = machine.activate(at: now)
        _ = machine.setSensing(true, at: now)
        hold(2, for: 6)
        XCTAssertNil(machine.usualCount(at: now))
        XCTAssertEqual(hold(4, for: 8), [], "a high count while learning becomes the baseline")
        hold(4, for: 4)
        XCTAssertEqual(machine.usualCount(at: now), 4)
    }

    func testTurningOnAgainLearnsAfresh() {
        startWatching(usual: 2)
        _ = machine.deactivate(at: now)
        XCTAssertNil(machine.usualCount(at: now))
        XCTAssertEqual(machine.activate(at: now), [.startScanning])
        XCTAssertTrue(machine.baseline.isLearning)
    }

    func testFocusLeftOnByAnEarlierRunIsTurnedOffOnStart() {
        machine = PresenceGuardMachine(focusOnByGuard: true)
        _ = machine.setUserActive(true, at: now)
        XCTAssertEqual(machine.activate(at: now), [.setFocus(false), .startScanning])
        XCTAssertFalse(machine.focusOnByGuard)
    }

    func testFocusLeftOnIsTurnedOffEvenIfAlertModeIsOff() {
        machine = PresenceGuardMachine(focusOnByGuard: true)
        XCTAssertEqual(machine.deactivate(at: now), [.setFocus(false)])
    }

    // MARK: Suspicion and checks

    func testTheCameraOnlyLooksAfterASustainedExcess() {
        startWatching(usual: 2)
        advance(2)
        XCTAssertEqual(tick(3), [])
        XCTAssertEqual(machine.phase, .suspicious(since: now))
        XCTAssertEqual(hold(3, for: 4), [])
        // A dip resets it.
        advance(2)
        tick(2)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(hold(3, for: 6), [])
        XCTAssertEqual(hold(3, for: 2), [.startFaceCheck])
    }

    func testFewerDevicesThanUsualNeverTrigger() {
        startWatching(usual: 2)
        XCTAssertEqual(hold(0, for: 60), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAloneAtACountMeansNoMoreChecksUntilMoreArrive() {
        startWatching(usual: 2)
        XCTAssertEqual(hold(3, for: 8), [.startFaceCheck])
        XCTAssertEqual(machine.faceCheckFinished(.alone, at: now), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.usualCount(at: now), 3)
        XCTAssertEqual(hold(3, for: 120), [], "the Bluetooth picture hasn't changed")

        // One more device: suspicious again, and checked straight away since
        // the last check was over a minute ago.
        XCTAssertEqual(hold(4, for: 8), [.startFaceCheck])
    }

    func testChecksAreAtMostOneAMinute() {
        startWatching(usual: 2)
        XCTAssertEqual(hold(3, for: 8), [.startFaceCheck])
        _ = machine.faceCheckFinished(.alone, at: now)
        // More arrive 20 s later: suspicious, but the check waits.
        hold(3, for: 12)
        XCTAssertEqual(hold(4, for: 30), [])
        if case .suspicious = machine.phase {} else { XCTFail("expected suspicious, got \(machine.phase)") }
        XCTAssertEqual(hold(4, for: 20), [.startFaceCheck])
    }

    func testAnAloneCountExpires() {
        startWatching(usual: 2)
        XCTAssertEqual(hold(3, for: 8), [.startFaceCheck])
        _ = machine.faceCheckFinished(.alone, at: now)
        // Back to the usual two for eleven minutes, then three again.
        hold(2, for: 660)
        XCTAssertEqual(machine.usualCount(at: now), 2)
        XCTAssertEqual(hold(3, for: 8), [.startFaceCheck])
    }

    func testAnAloneCountThatStaysBecomesUsual() {
        startWatching(usual: 2)
        hold(3, for: 8)
        _ = machine.faceCheckFinished(.alone, at: now)
        hold(3, for: 660)
        XCTAssertEqual(machine.baseline.value, 3)
        XCTAssertEqual(hold(3, for: 60), [])
    }

    func testABusyCameraDefersTheCheck() {
        startWatching(usual: 2)
        XCTAssertEqual(hold(3, for: 30, camera: false), [])
        XCTAssertEqual(hold(3, for: 2, camera: true), [.startFaceCheck])
    }

    func testTheMirrorOpeningMidCheckCancelsIt() {
        startWatching(usual: 2)
        hold(3, for: 8)
        advance(1)
        XCTAssertEqual(tick(3, camera: false), [.cancelFaceCheck])
        // Retried soon, not after a full minute.
        XCTAssertEqual(hold(3, for: 14), [])
        XCTAssertEqual(hold(3, for: 2), [.startFaceCheck])
    }

    func testAnUnavailableCheckIsRetriedSoon() {
        startWatching(usual: 2)
        hold(3, for: 8)
        XCTAssertEqual(machine.faceCheckFinished(.unavailable, at: now), [])
        XCTAssertEqual(hold(3, for: 14), [])
        XCTAssertEqual(hold(3, for: 2), [.startFaceCheck])
    }

    func testACheckThatNeverAnswersIsGivenUp() {
        startWatching(usual: 2)
        hold(3, for: 8)
        XCTAssertEqual(hold(3, for: 8), [])
        XCTAssertEqual(hold(3, for: 2), [.cancelFaceCheck])
        // A late answer changes nothing.
        XCTAssertEqual(machine.faceCheckFinished(.confirmed, at: now), [])
        XCTAssertFalse(machine.focusOnByGuard)
    }

    // MARK: Guarding and clearing

    func testFocusGoesOffOnceTheCountHasBeenUsualForThirtySeconds() {
        startGuarding(usual: 2)
        XCTAssertEqual(hold(3, for: 60), [], "no more camera checks while guarding")
        XCTAssertEqual(hold(2, for: 20), [])
        // Back for a moment: the wait starts over.
        XCTAssertEqual(hold(3, for: 2), [])
        XCTAssertEqual(machine.phase, .guarding)
        XCTAssertEqual(hold(2, for: 28), [])
        XCTAssertEqual(hold(2, for: 4), [.setFocus(false)])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.focusOnByGuard)
    }

    func testClearingAllowsForYourOwnExtraDevices() {
        startWatching(usual: 2)
        // Your AirPods come out: checked, alone.
        hold(3, for: 8)
        _ = machine.faceCheckFinished(.alone, at: now)
        // Then a visitor, confirmed, who leaves after a while.
        hold(3, for: 60)
        XCTAssertEqual(hold(4, for: 8), [.startFaceCheck])
        XCTAssertEqual(machine.faceCheckFinished(.confirmed, at: now), [.setFocus(true)])
        hold(4, for: 600)
        XCTAssertEqual(hold(3, for: 32), [.setFocus(false)])
    }

    func testOnlyTurnsOffAFocusItTurnedOn() {
        startGuarding(usual: 2)
        // The On shortcut failed: Focus never came on.
        machine.focusCommandFailed(turningOn: true, at: now)
        XCTAssertFalse(machine.focusOnByGuard)
        XCTAssertEqual(hold(2, for: 40), [])
        XCTAssertEqual(machine.deactivate(at: now), [.stopScanning])
    }

    func testNeverGuardedMeansNothingToTurnOff() {
        startWatching(usual: 2)
        XCTAssertEqual(machine.deactivate(at: now), [.stopScanning])
    }

    func testAlertModeOffWhileGuardingTurnsFocusOffThenStops() {
        startGuarding(usual: 2)
        XCTAssertEqual(machine.deactivate(at: now), [.setFocus(false), .stopScanning])
        XCTAssertEqual(machine.phase, .inactive)
        XCTAssertEqual(tick(5), [])
    }

    func testAlertModeOffMidCheckStopsTheCamera() {
        startWatching(usual: 2)
        hold(3, for: 8)
        XCTAssertEqual(machine.deactivate(at: now), [.cancelFaceCheck, .stopScanning])
    }

    func testAFailedTurnOffIsRetried() {
        startGuarding(usual: 2)
        XCTAssertEqual(hold(2, for: 32), [.setFocus(false)])
        machine.focusCommandFailed(turningOn: false, at: now)
        XCTAssertTrue(machine.focusOnByGuard)
        XCTAssertEqual(hold(2, for: 58), [])
        XCTAssertEqual(hold(2, for: 2), [.setFocus(false)])
    }

    func testRecalibratingStandsDown() {
        startGuarding(usual: 2)
        XCTAssertEqual(machine.recalibrate(at: now), [.setFocus(false)])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.baseline.isLearning)
        // Learns the current count, visitor and all.
        hold(3, for: 12)
        XCTAssertEqual(machine.usualCount(at: now), 3)
    }

    // MARK: Pausing

    func testGoingAwayLeavesFocusAloneAndComingBackReevaluates() {
        startGuarding(usual: 2)
        XCTAssertEqual(machine.setUserActive(false, at: now), [.stopScanning])
        XCTAssertEqual(machine.phase, .inactive)
        XCTAssertTrue(machine.focusOnByGuard)
        _ = machine.setSensing(false, at: now)
        advance(3600)
        XCTAssertEqual(tick(2), [])

        // Back, and the visitor's gone: no camera, Focus off after the wait.
        XCTAssertEqual(machine.setUserActive(true, at: now), [.startScanning])
        _ = machine.setSensing(true, at: now)
        XCTAssertEqual(hold(2, for: 6), [])
        XCTAssertEqual(machine.phase, .clearing(since: now))
        XCTAssertEqual(hold(2, for: 30), [.setFocus(false)])
    }

    func testComingBackWithTheVisitorStillThereKeepsGuarding() {
        startGuarding(usual: 2)
        _ = machine.setUserActive(false, at: now)
        _ = machine.setSensing(false, at: now)
        advance(600)
        _ = machine.setUserActive(true, at: now)
        _ = machine.setSensing(true, at: now)
        XCTAssertEqual(hold(3, for: 120), [], "no camera needed, Focus stays")
        XCTAssertEqual(machine.phase, .guarding)
    }

    func testGoingAwayMidCheckStopsTheCamera() {
        startWatching(usual: 2)
        hold(3, for: 8)
        XCTAssertEqual(machine.setUserActive(false, at: now), [.cancelFaceCheck, .stopScanning])
    }

    func testBluetoothTurningOffPausesWithoutTouchingFocus() {
        startGuarding(usual: 2)
        XCTAssertEqual(machine.setSensing(false, at: now), [])
        XCTAssertEqual(machine.phase, .inactive)
        XCTAssertEqual(hold(0, for: 60), [], "no counts of zero while Bluetooth is off")
        XCTAssertTrue(machine.focusOnByGuard)
    }

    func testABaselineSurvivesAPause() {
        startWatching(usual: 2)
        _ = machine.setUserActive(false, at: now)
        _ = machine.setSensing(false, at: now)
        advance(1800)
        _ = machine.setUserActive(true, at: now)
        _ = machine.setSensing(true, at: now)
        hold(2, for: 6)
        XCTAssertEqual(machine.usualCount(at: now), 2)
    }

    // MARK: Bluetooth churn end to end

    func testYourPhoneRotatingItsAddressNeverWakesTheCamera() {
        var tracker = ProximityTracker()
        let start = now
        var effects: [Effect] = []
        var ids = [UUID()]
        _ = machine.setUserActive(true, at: now)
        _ = machine.activate(at: now)
        _ = machine.setSensing(true, at: now)
        // Five minutes of a phone advertising every 0.3 s, rotating its
        // address every 40 s, read every 2 s.
        var time: TimeInterval = 0
        var nextTick: TimeInterval = 2
        while time < 300 {
            if Int(time / 40) >= ids.count { ids.append(UUID()) }
            tracker.observe(ids.last!, kind: .personal, rssi: -52 + Int(time * 7) % 5, at: start.addingTimeInterval(time))
            if time >= nextTick {
                now = start.addingTimeInterval(time)
                tracker.prune(at: now)
                effects += tick(tracker.nearCount(at: now))
                nextTick += 2
            }
            time += 0.3
        }
        XCTAssertEqual(machine.usualCount(at: now), 1)
        XCTAssertFalse(effects.contains(.startFaceCheck))
    }
}

// MARK: - Camera check

final class FaceCheckTallyTests: XCTestCase {
    func testTwoFramesWithCompanyConfirm() {
        var tally = FaceCheckTally()
        XCTAssertNil(tally.add(faceCount: 2))
        XCTAssertNil(tally.add(faceCount: 1))
        XCTAssertEqual(tally.add(faceCount: 3), .confirmed)
    }

    func testOneFlukeFrameIsntEnough() {
        var tally = FaceCheckTally()
        var result: FaceCheckResult?
        for count in [2, 1, 1, 1, 1, 1, 1, 1] where result == nil {
            result = tally.add(faceCount: count)
        }
        XCTAssertEqual(result, .alone)
        XCTAssertEqual(tally.analyzed, 8)
    }

    func testStopsAsSoonAsConfirmingIsImpossible() {
        var tally = FaceCheckTally()
        for _ in 0..<6 { XCTAssertNil(tally.add(faceCount: 1)) }
        XCTAssertEqual(tally.add(faceCount: 1), .alone)
        XCTAssertEqual(tally.analyzed, 7)
    }

    func testTooFewFramesByTheDeadlineIsNoAnswer() {
        var tally = FaceCheckTally()
        XCTAssertEqual(tally.resultAtDeadline, .unavailable)
        for _ in 0..<3 { _ = tally.add(faceCount: 1) }
        XCTAssertEqual(tally.resultAtDeadline, .unavailable)
        _ = tally.add(faceCount: 1)
        XCTAssertEqual(tally.resultAtDeadline, .alone)
    }

    func testSmallAndUnsureFacesDontCount() {
        let faces: [(box: CGRect, confidence: Float)] = [
            (CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4), 0.99),   // you
            (CGRect(x: 0.8, y: 0.6, width: 0.1, height: 0.12), 0.95),  // someone behind you
            (CGRect(x: 0.1, y: 0.8, width: 0.03, height: 0.04), 0.99), // across the room
            (CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2), 0.2),    // a guess
        ]
        XCTAssertEqual(PresenceFaces.count(faces), 2)
    }
}

// MARK: - User activity

final class UserActivityStateTests: XCTestCase {
    func testActiveOnlyWhileUnlockedAwakeAndRecentlyUsed() {
        var state = UserActivityState()
        XCTAssertTrue(state.isActive)
        state.idleSeconds = UserActivityState.idleLimit - 1
        XCTAssertTrue(state.isActive)
        state.idleSeconds = UserActivityState.idleLimit
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.isAwake, "still polled, to notice them coming back")

        for change in [
            { (s: inout UserActivityState) in s.isLocked = true },
            { (s: inout UserActivityState) in s.displaysAsleep = true },
            { (s: inout UserActivityState) in s.systemAsleep = true },
            { (s: inout UserActivityState) in s.sessionInactive = true },
        ] {
            var other = UserActivityState()
            change(&other)
            XCTAssertFalse(other.isActive)
            XCTAssertFalse(other.isAwake, "nothing polls while locked or asleep")
        }

        var screenSaver = UserActivityState()
        screenSaver.screenSaverRunning = true
        XCTAssertFalse(screenSaver.isActive)
    }
}

// MARK: - The guard with fake adapters

private final class FakeScanner: ProximityScanning {
    var onSensingChange: (@MainActor @Sendable (Bool) -> Void)?
    var count = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var threshold: Double?
    var isScanning: Bool { starts > stops }

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func setThreshold(_ dBm: Double) { threshold = dBm }
    func nearCount(at now: Date) -> Int { count }
}

private final class FakeFaceChecker: FaceChecking {
    var isAuthorized = true
    private(set) var starts = 0
    private(set) var cancels = 0
    private var completion: (@MainActor @Sendable (FaceCheckResult) -> Void)?

    func start(completion: @escaping @MainActor @Sendable (FaceCheckResult) -> Void) {
        starts += 1
        self.completion = completion
    }

    func cancel() { cancels += 1 }

    @MainActor func answer(_ result: FaceCheckResult) { completion?(result) }
}

private actor FakeFocus: FocusControlling {
    private(set) var commands: [Bool] = []
    var succeeds = true
    func setSucceeds(_ value: Bool) { succeeds = value }
    func setFocus(_ on: Bool) async -> Bool {
        commands.append(on)
        return succeeds
    }
    func installedShortcuts() async -> Set<FocusShortcut>? { [.on] }
}

@MainActor
private final class FakeActivity: UserActivityMonitoring {
    var isActive = true
    var onChange: ((Bool) -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func set(_ active: Bool) {
        isActive = active
        onChange?(active)
    }
}

@MainActor
final class PresenceGuardControllerTests: XCTestCase {
    private var scanner: FakeScanner!
    private var camera: FakeFaceChecker!
    private var focus: FakeFocus!
    private var activity: FakeActivity!
    private var clock = Date(timeIntervalSinceReferenceDate: 0)
    private var persisted: [Bool] = []
    private var presence: PresenceGuard!

    override func setUp() async throws {
        scanner = FakeScanner()
        camera = FakeFaceChecker()
        focus = FakeFocus()
        activity = FakeActivity()
        persisted = []
        presence = makeGuard(focusOnByGuard: false)
    }

    private func makeGuard(focusOnByGuard: Bool) -> PresenceGuard {
        PresenceGuard(
            scanner: scanner,
            faceChecker: camera,
            focus: focus,
            activity: activity,
            focusOnByGuard: focusOnByGuard,
            schedulesTicks: false,
            now: { [unowned self] in self.clock },
            persistFocusFlag: { [unowned self] in self.persisted.append($0) }
        )
    }

    private func hold(_ count: Int, for seconds: TimeInterval) {
        scanner.count = count
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            clock = clock.addingTimeInterval(2)
            elapsed += 2
            presence.tick()
        }
    }

    private func startWatching(usual: Int = 2) {
        presence.update(enabled: true, alertMode: true)
        scanner.onSensingChange?(true)
        hold(usual, for: 18)
        XCTAssertEqual(presence.state, .watching)
        XCTAssertEqual(presence.usualCount, usual)
    }

    private func startGuarding() async {
        startWatching()
        hold(3, for: 8)
        XCTAssertEqual(camera.starts, 1)
        XCTAssertEqual(presence.state, .checking)
        camera.answer(.confirmed)
        await presence.waitForFocusCommands()
        XCTAssertEqual(presence.state, .guarding)
    }

    func testWithAlertModeOffNothingRuns() {
        presence.update(enabled: true, alertMode: false)
        presence.update(enabled: false, alertMode: true)
        XCTAssertEqual(scanner.starts, 0)
        XCTAssertFalse(activity.isStarted)
        XCTAssertEqual(presence.state, .off)
    }

    func testAlertModeOnStartsListening() {
        presence.update(enabled: true, alertMode: true)
        XCTAssertEqual(scanner.starts, 1)
        XCTAssertTrue(activity.isStarted)
        XCTAssertEqual(presence.state, .paused, "until Bluetooth reports in")
        scanner.onSensingChange?(true)
        XCTAssertEqual(presence.state, .watching)
        XCTAssertNil(presence.usualCount, "learning")
    }

    func testSensitivityReachesTheScanner() {
        presence.setSensitivity(.high)
        XCTAssertEqual(scanner.threshold, PresenceSensitivity.high.threshold)
    }

    func testAConfirmedVisitorTurnsFocusOnAndItsRemembered() async {
        await startGuarding()
        let commands = await focus.commands
        XCTAssertEqual(commands, [true])
        XCTAssertTrue(presence.turnedFocusOn)
        XCTAssertEqual(persisted, [true])
    }

    func testAlertModeOffWhileGuardingTurnsFocusOffAndStopsEverything() async {
        await startGuarding()
        presence.update(enabled: true, alertMode: false)
        await presence.waitForFocusCommands()
        let commands = await focus.commands
        XCTAssertEqual(commands, [true, false])
        XCTAssertFalse(scanner.isScanning)
        XCTAssertFalse(activity.isStarted)
        XCTAssertEqual(presence.state, .off)
        XCTAssertEqual(persisted, [true, false])
    }

    func testAFailedShortcutLeavesNothingToTurnOff() async {
        await focus.setSucceeds(false)
        await startGuarding()
        XCTAssertFalse(presence.turnedFocusOn)
        hold(2, for: 40)
        presence.update(enabled: false, alertMode: false)
        await presence.waitForFocusCommands()
        let commands = await focus.commands
        XCTAssertEqual(commands, [true], "never asked to turn off what didn't come on")
    }

    func testTheCameraWaitsForTheMirror() {
        var mirrorOpen = true
        presence.isCameraBusy = { mirrorOpen }
        startWatching()
        hold(3, for: 20)
        XCTAssertEqual(camera.starts, 0)
        mirrorOpen = false
        hold(3, for: 2)
        XCTAssertEqual(camera.starts, 1)
    }

    func testNoCameraAccessMeansNoChecks() {
        camera.isAuthorized = false
        startWatching()
        hold(3, for: 60)
        XCTAssertEqual(camera.starts, 0)
    }

    func testGoingAwayPausesButLeavesFocusOn() async {
        await startGuarding()
        activity.set(false)
        scanner.onSensingChange?(false)
        await presence.waitForFocusCommands()
        XCTAssertFalse(scanner.isScanning)
        XCTAssertEqual(presence.state, .paused)
        XCTAssertTrue(presence.turnedFocusOn)
        let commands = await focus.commands
        XCTAssertEqual(commands, [true])

        activity.set(true)
        XCTAssertTrue(scanner.isScanning)
    }

    func testALateAnswerFromACancelledCheckIsIgnored() async {
        startWatching()
        hold(3, for: 8)
        XCTAssertEqual(camera.starts, 1)
        activity.set(false)
        XCTAssertEqual(camera.cancels, 1)
        camera.answer(.confirmed)
        await presence.waitForFocusCommands()
        let commands = await focus.commands
        XCTAssertEqual(commands, [])
        XCTAssertEqual(presence.state, .paused)
    }

    func testFocusLeftOnByAnEarlierRunIsTurnedOffAtLaunch() async {
        presence = makeGuard(focusOnByGuard: true)
        XCTAssertTrue(presence.turnedFocusOn)
        presence.update(enabled: true, alertMode: false)
        await presence.waitForFocusCommands()
        let commands = await focus.commands
        XCTAssertEqual(commands, [false])
        XCTAssertFalse(presence.turnedFocusOn)
    }
}
