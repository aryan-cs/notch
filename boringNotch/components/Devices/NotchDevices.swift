//
//  NotchDevices.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The devices tab's data: paired Bluetooth devices (with battery where the
//  device reports it) merged with the Mac's audio outputs, so a Bluetooth
//  speaker shows once with both "connect" and "play sound here".
//
//  Battery sources, by what macOS actually exposes:
//   • Magic Keyboard / Mouse / Trackpad: `BatteryPercent` on their
//     AppleDeviceManagementHIDEventService in the I/O registry.
//   • AirPods and Beats: per-bud and case levels on IOBluetoothDevice
//     (undocumented keys, read defensively).
//   • Everything else: only if the device reports a level at all — many
//     speakers (e.g. JBL Go) never do, and then there's nothing to show.
//   • iPhone, iPad and Apple Watch: not over Bluetooth at all. The XPC
//     helper's notch-appledevices tool (libimobiledevice, the approach
//     AirBattery takes) reads trusted devices over USB or Wi-Fi.
//

import AppKit
import Combine
import CoreAudio
import CoreBluetooth
import Defaults
import IOBluetooth
import IOKit

struct DeviceBattery: Equatable {
    var single: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var isCharging = false

    var isEmpty: Bool { single == nil && left == nil && right == nil && caseLevel == nil }
}

/// An iPhone, iPad or Apple Watch as reported by the helper's tool.
struct AppleDeviceReading: Codable, Equatable {
    let id: String
    let name: String
    let model: String
    let deviceClass: String
    let battery: Int
    let charging: Bool
    /// The iPhone a watch was read through.
    let parent: String?
    /// For Find My's device link.
    var serial: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, model, battery, charging, parent, serial
        case deviceClass = "class"
    }

    static func decodeList(_ data: Data) -> [AppleDeviceReading]? {
        try? JSONDecoder().decode([AppleDeviceReading].self, from: data)
    }
}

/// The last reading of each iPhone, iPad and watch, kept so their cards stay
/// when they can't be reached: iOS stops answering over Wi-Fi once a phone
/// is unplugged and asleep, and starts again when it's woken or charged.
struct KnownAppleDevices: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var reading: AppleDeviceReading
        var lastSeen: Date
    }

    private(set) var entries: [Entry] = []

    /// How long an unreachable device keeps its card.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// Records a fetch: readings in it are fresh, the rest keep their last
    /// values, and anything unseen for a week is dropped.
    mutating func record(_ readings: [AppleDeviceReading], at now: Date = Date()) {
        var byID = Dictionary(entries.map { ($0.reading.id, $0) }, uniquingKeysWith: { $1 })
        for reading in readings { byID[reading.id] = Entry(reading: reading, lastSeen: now) }
        entries = byID.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.retention }
            .sorted { $0.reading.name.localizedCompare($1.reading.name) == .orderedAscending }
    }

    /// Known devices missing from the latest fetch.
    func unreachable(excluding readings: [AppleDeviceReading]) -> [Entry] {
        let current = Set(readings.map(\.id))
        return entries.filter { !current.contains($0.reading.id) }
    }
}

/// A paired Bluetooth device as read from IOBluetooth.
struct BluetoothDeviceSnapshot: Equatable {
    let address: String
    let name: String
    let isConnected: Bool
    let majorClass: UInt32
    let minorClass: UInt32
    let battery: DeviceBattery
}

struct NotchDevice: Identifiable, Equatable {
    enum Kind: Equatable {
        case earbuds(String)  // SF Symbol, e.g. "airpodspro"
        case headphones
        case speaker
        case keyboard
        case mouse
        case trackpad
        case gameController
        case phone
        case tablet
        case watch
        case computer
        case audioOutput(String)  // a non-Bluetooth output, with its own symbol
        case other
    }

    let id: String
    let name: String
    let kind: Kind
    /// Present for Bluetooth devices: what connect/disconnect acts on.
    let bluetoothAddress: String?
    let isConnected: Bool
    let battery: DeviceBattery
    /// Present when sound can play here right now.
    let audioOutputID: AudioDeviceID?
    /// For an iPhone, iPad or watch that can't be reached now: when its
    /// battery (the last known level) was read.
    var lastSeen: Date? = nil
    /// iPhones, iPads and watches: opens the device in Find My.
    var serialNumber: String? = nil

    /// An iPhone, iPad or watch read over USB/Wi-Fi rather than Bluetooth.
    var isAppleDevice: Bool { id.hasPrefix("apple-") }

    /// Speakers, headphones and other outputs — things sound can play on.
    var isAudio: Bool {
        switch kind {
        case .earbuds, .headphones, .speaker, .audioOutput: return true
        default: return false
        }
    }

    var systemImage: String {
        switch kind {
        case .earbuds(let symbol), .audioOutput(let symbol): return symbol
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse.fill"
        case .trackpad: return "hand.point.up.left.fill"
        case .gameController: return "gamecontroller.fill"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .watch: return "applewatch"
        case .computer: return "laptopcomputer"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

enum NotchDevices {
    /// One list for the tab: each Bluetooth device merged with its audio
    /// output (matched by name), iPhones/iPads/watches, then the remaining
    /// outputs. Order: current output, connected devices (Apple devices
    /// included), other outputs, disconnected devices.
    static func merge(
        bluetooth: [BluetoothDeviceSnapshot],
        outputs: [AudioOutputDevice],
        activeOutputID: AudioDeviceID,
        appleDevices: [AppleDeviceReading] = [],
        unreachableAppleDevices: [KnownAppleDevices.Entry] = [],
        macBattery: DeviceBattery = DeviceBattery()
    ) -> [NotchDevice] {
        // An iPhone paired over Bluetooth too would otherwise show twice;
        // the reading has its battery, the Bluetooth entry doesn't.
        let appleNames = Set((appleDevices + unreachableAppleDevices.map(\.reading)).map { $0.name.lowercased() })
        let bluetooth = bluetooth.filter { !appleNames.contains($0.name.lowercased()) }

        var unmatchedOutputs = outputs
        var devices: [NotchDevice] = bluetooth.map { snapshot in
            let output = snapshot.isConnected
                ? unmatchedOutputs.firstIndex { $0.name.caseInsensitiveCompare(snapshot.name) == .orderedSame }
                : nil
            let outputID = output.map { unmatchedOutputs.remove(at: $0).id }
            return NotchDevice(
                id: "bt-\(normalizedAddress(snapshot.address))",
                name: snapshot.name,
                kind: kind(for: snapshot),
                bluetoothAddress: snapshot.address,
                isConnected: snapshot.isConnected,
                battery: snapshot.battery,
                audioOutputID: outputID
            )
        }
        devices += appleDevices.map { reading in
            NotchDevice(
                id: "apple-\(reading.id)",
                name: reading.name,
                kind: appleKind(reading.deviceClass),
                bluetoothAddress: nil,
                isConnected: true,
                battery: DeviceBattery(single: reading.battery, isCharging: reading.charging),
                audioOutputID: nil,
                serialNumber: reading.serial
            )
        }
        // Last known level; never "charging", which may no longer be true.
        devices += unreachableAppleDevices.map { entry in
            NotchDevice(
                id: "apple-\(entry.reading.id)",
                name: entry.reading.name,
                kind: appleKind(entry.reading.deviceClass),
                bluetoothAddress: nil,
                isConnected: false,
                battery: DeviceBattery(single: entry.reading.battery),
                audioOutputID: nil,
                lastSeen: entry.lastSeen,
                serialNumber: entry.reading.serial
            )
        }
        devices += unmatchedOutputs.map { output in
            NotchDevice(
                id: "out-\(output.id)",
                name: output.name,
                kind: .audioOutput(output.iconName),
                bluetoothAddress: nil,
                isConnected: true,
                // A MacBook's own speakers stand in for the Mac itself.
                battery: output.transportType == kAudioDeviceTransportTypeBuiltIn && output.iconName == AudioOutputDevice.macSymbol
                    ? macBattery
                    : DeviceBattery(),
                audioOutputID: output.id
            )
        }

        func rank(_ device: NotchDevice) -> Int {
            if device.audioOutputID == activeOutputID { return 0 }
            if device.bluetoothAddress != nil && device.isConnected { return 1 }
            if device.isAppleDevice { return device.isConnected ? 1 : 3 }
            if device.bluetoothAddress == nil { return 2 }
            return 3
        }
        return devices.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (rank(lhs.element), rank(rhs.element))
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func appleKind(_ deviceClass: String) -> NotchDevice.Kind {
        switch deviceClass {
        case "iPhone": return .phone
        case "iPad": return .tablet
        case "Watch": return .watch
        default: return .other
        }
    }

    static func kind(for snapshot: BluetoothDeviceSnapshot) -> NotchDevice.Kind {
        let name = snapshot.name.lowercased()
        if name.contains("airpods max") { return .headphones }
        if name.contains("airpods pro") { return .earbuds("airpodspro") }
        if name.contains("airpods") { return .earbuds("airpods") }
        if name.contains("trackpad") { return .trackpad }
        if name.contains("mouse") { return .mouse }
        if name.contains("keyboard") { return .keyboard }

        switch snapshot.majorClass {
        case 0x04:  // audio/video
            return isSpeaker(major: snapshot.majorClass, minor: snapshot.minorClass) == true ? .speaker : .headphones
        case 0x05:  // peripheral: keyboard and pointing bits in the minor class
            if snapshot.minorClass & 0x10 != 0 { return .keyboard }
            if snapshot.minorClass & 0x20 != 0 { return .mouse }
            if snapshot.minorClass & 0x0F == 0x01 || snapshot.minorClass & 0x0F == 0x02 { return .gameController }
            return .other
        case 0x02: return .phone
        case 0x01: return .computer
        default: return .other
        }
    }

    /// For a Bluetooth audio device's class: true for speakers (loudspeaker,
    /// portable, car or hi-fi audio), false for things worn on the head
    /// (headset, hands-free, headphones), nil when the class doesn't say.
    static func isSpeaker(major: UInt32, minor: UInt32) -> Bool? {
        guard major == 0x04 else { return nil }
        switch minor {
        case 0x05, 0x07, 0x08, 0x0A: return true
        case 0x01, 0x02, 0x06: return false
        default: return nil
        }
    }

    /// The Bluetooth address inside a Core Audio device UID, which for
    /// Bluetooth outputs looks like "AA-BB-CC-DD-EE-FF:output".
    static func bluetoothAddress(fromAudioUID uid: String) -> String? {
        guard let range = uid.range(of: "([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}", options: .regularExpression) else {
            return nil
        }
        return String(uid[range])
    }

    /// "aa:bb:cc…" and "AA-BB-CC…" compare equal.
    static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// A percentage worth showing: 1…100. Zero and out-of-range values mean
    /// "unknown" in these APIs.
    static func validLevel(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let level = number.intValue
        return (1...100).contains(level) ? level : nil
    }
}

// MARK: - Live sources

/// Reads paired Bluetooth devices and the battery levels macOS knows about.
enum BluetoothDeviceSource {
    static func snapshots() -> [BluetoothDeviceSnapshot] {
        let hidLevels = hidBatteryLevelsByAddress()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            var battery = budBattery(for: device)
            if battery.isEmpty, let level = hidLevels[NotchDevices.normalizedAddress(address)] {
                battery.single = level
            }
            return BluetoothDeviceSnapshot(
                address: address,
                name: device.name ?? address,
                isConnected: device.isConnected(),
                majorClass: device.deviceClassMajor,
                minorClass: device.deviceClassMinor,
                battery: battery
            )
        }
    }

    /// AirPods/Beats levels. These keys aren't public API, so each is only
    /// read if the object answers to it.
    private static func budBattery(for device: IOBluetoothDevice) -> DeviceBattery {
        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)) else { return nil }
            return NotchDevices.validLevel(device.value(forKey: key))
        }
        return DeviceBattery(
            single: level("batteryPercentSingle"),
            left: level("batteryPercentLeft"),
            right: level("batteryPercentRight"),
            caseLevel: level("batteryPercentCase")
        )
    }

    /// Magic accessories publish their level on a HID service in the I/O
    /// registry, keyed here by Bluetooth address.
    private static func hidBatteryLevelsByAddress() -> [String: Int] {
        var levels: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return levels }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let address = property("DeviceAddress") as? String,
               let level = NotchDevices.validLevel(property("BatteryPercent")) {
                levels[NotchDevices.normalizedAddress(address)] = level
            }
        }
        return levels
    }
}

/// macOS's Bluetooth permission. Without it IOBluetooth quietly reports
/// nothing useful and connects fail, so the devices view asks for it when
/// opened rather than leaving it to whichever call happens to trip it.
@MainActor
final class BluetoothPermission: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = BluetoothPermission()

    @Published private(set) var status: CBManagerAuthorization = CBCentralManager.authorization

    var isAllowed: Bool { status == .allowedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    private var central: CBCentralManager?

    /// Shows the system prompt the first time; later calls just re-read the status.
    func requestIfNeeded() {
        status = CBCentralManager.authorization
        guard status == .notDetermined, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.status = CBCentralManager.authorization
        }
    }
}

/// Keeps the devices tab current while it's on screen.
@MainActor
final class NotchDevicesModel: ObservableObject {
    @Published private(set) var devices: [NotchDevice] = []
    /// Devices mid-connect or mid-disconnect, to show progress on their card.
    @Published private(set) var busyIDs: Set<String> = []
    /// Devices whose last connect attempt failed, flagged for a few seconds.
    @Published private(set) var failedIDs: Set<String> = []

    private let audio = AudioRouteManager.shared
    private let permission = BluetoothPermission.shared
    private var timer: Timer?
    private var appleTimer: Timer?
    private var bluetooth: [BluetoothDeviceSnapshot] = []
    private var permissionCancellable: AnyCancellable?
    /// Last iPhone/iPad/watch readings, kept across openings: the tool can
    /// take several seconds over Wi-Fi, so reopening shows these right away.
    private static var appleDevices: [AppleDeviceReading] = []
    private static var appleDevicesFetchedAt: Date?
    /// Persisted, so a phone keeps its card across launches too.
    private static var knownAppleDevices: KnownAppleDevices = {
        guard let data = Defaults[.knownAppleDevices] else { return KnownAppleDevices() }
        return (try? JSONDecoder().decode(KnownAppleDevices.self, from: data)) ?? KnownAppleDevices()
    }()
    private var isFetchingAppleDevices = false

    var activeOutputID: AudioDeviceID { audio.activeDeviceID }

    func start() {
        permission.requestIfNeeded()
        permissionCancellable = permission.$status
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // @Published fires before the new value lands; refresh after.
                Task { @MainActor in self?.refresh() }
            }
        refresh()
        guard timer == nil else { return }
        // Connection changes and battery levels have no cheap push
        // notification that covers every source, so poll while visible.
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Phones and watches report through a slower path; once a minute
        // is plenty for battery levels.
        if Self.appleDevicesFetchedAt.map({ Date().timeIntervalSince($0) > 50 }) ?? true {
            fetchAppleDevices()
        }
        let appleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchAppleDevices() }
        }
        appleTimer.tolerance = 10
        RunLoop.main.add(appleTimer, forMode: .common)
        self.appleTimer = appleTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        appleTimer?.invalidate()
        appleTimer = nil
    }

    private func fetchAppleDevices() {
        guard !isFetchingAppleDevices else { return }
        isFetchingAppleDevices = true
        Task {
            defer { isFetchingAppleDevices = false }
            guard let data = await XPCHelperClient.shared.fetchAppleDevices(),
                  let readings = AppleDeviceReading.decodeList(data)
            else { return }
            Self.appleDevices = readings
            Self.appleDevicesFetchedAt = Date()
            Self.knownAppleDevices.record(readings)
            Defaults[.knownAppleDevices] = try? JSONEncoder().encode(Self.knownAppleDevices)
            rebuild()
        }
    }

    func refresh() {
        // Audio outputs work without Bluetooth access; paired devices don't.
        bluetooth = permission.isAllowed ? BluetoothDeviceSource.snapshots() : []
        audio.refreshDevices { [weak self] in
            self?.rebuild()
        }
        rebuild()
    }

    /// This Mac's battery, from the same model as the header's battery icon.
    private static func macBattery() -> DeviceBattery {
        let battery = BatteryStatusViewModel.shared
        let level = Int(battery.levelBattery.rounded())
        guard (1...100).contains(level) else { return DeviceBattery() }
        return DeviceBattery(single: level, isCharging: battery.isCharging)
    }

    private func rebuild() {
        devices = NotchDevices.merge(
            bluetooth: bluetooth,
            outputs: audio.devices,
            activeOutputID: audio.activeDeviceID,
            appleDevices: Self.appleDevices,
            unreachableAppleDevices: Self.knownAppleDevices.unreachable(excluding: Self.appleDevices),
            macBattery: Self.macBattery()
        )
    }

    /// What a tap does: connect a disconnected device (and play through it
    /// if it's audio), or make a connected output the output. Never
    /// disconnects — that's in the context menu, so switching outputs can't
    /// drop a speaker by accident.
    func primaryAction(_ device: NotchDevice) {
        if device.bluetoothAddress != nil && !device.isConnected {
            connect(device)
        } else if device.audioOutputID != nil {
            makeOutput(device)
        }
    }

    func makeOutput(_ device: NotchDevice) {
        guard let outputID = device.audioOutputID,
              let output = audio.devices.first(where: { $0.id == outputID })
        else { return }
        audio.select(output)
        // select() refreshes the device list; rebuild once it lands.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.rebuild()
        }
    }

    /// Pages the device (up to ~10s, double the default — speakers that
    /// were just dropped can be slow to answer), then for audio devices
    /// switches output to it once macOS lists it.
    func connect(_ device: NotchDevice) {
        guard let address = device.bluetoothAddress, !busyIDs.contains(device.id) else { return }
        busyIDs.insert(device.id)
        failedIDs.remove(device.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A nil target makes this synchronous. Page timeout is in 0.625ms slots.
            let result = IOBluetoothDevice(addressString: address)?
                .openConnection(nil, withPageTimeout: 16000, authenticationRequired: false) ?? kIOReturnNotFound
            Task { @MainActor in
                guard let self else { return }
                self.busyIDs.remove(device.id)
                if result == kIOReturnSuccess {
                    self.refresh()
                    if device.isAudio {
                        await self.playWhenAvailable(named: device.name)
                    }
                } else {
                    // Usually off, out of range, or connected to another device.
                    Log.general.notice("Bluetooth connect failed: \(result)")
                    self.failedIDs.insert(device.id)
                    try? await Task.sleep(for: .seconds(4))
                    self.failedIDs.remove(device.id)
                }
            }
        }
    }

    func disconnect(_ device: NotchDevice) {
        guard let address = device.bluetoothAddress, !busyIDs.contains(device.id) else { return }
        busyIDs.insert(device.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = IOBluetoothDevice(addressString: address)?.closeConnection() ?? kIOReturnNotFound
            if result != kIOReturnSuccess {
                Log.general.notice("Bluetooth disconnect failed: \(result)")
            }
            Task { @MainActor in
                self?.busyIDs.remove(device.id)
                self?.refresh()
            }
        }
    }

    /// A freshly connected speaker shows up as an output a beat after the
    /// Bluetooth link; wait for it (up to ~5s) and switch to it.
    private func playWhenAvailable(named name: String) async {
        for _ in 0..<10 {
            await withCheckedContinuation { continuation in
                audio.refreshDevices { continuation.resume() }
            }
            if let output = audio.devices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                audio.select(output)
                try? await Task.sleep(for: .milliseconds(300))
                refresh()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
