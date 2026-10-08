//
//  BluetoothProximityScanner.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Listens for Apple Continuity advertisements and keeps a ProximityTracker
//  current. Passive: it scans, never connects, and only reads the
//  manufacturer data and signal strength every advertisement already
//  carries. The central manager exists only while the guard is running, so
//  with Alert mode off nothing Bluetooth-related is left behind.
//

import CoreBluetooth
import Foundation
import os

final class BluetoothProximityScanner: NSObject, ProximityScanning, CBCentralManagerDelegate, @unchecked Sendable {
    private struct Shared {
        var tracker = ProximityTracker()
        var onSensingChange: (@MainActor @Sendable (Bool) -> Void)?
    }

    /// The tracker is written from the Bluetooth queue and read from the
    /// main actor every couple of seconds.
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "BoringNotch.PresenceGuard.bluetooth", qos: .utility)
    // Confined to `queue`:
    private var central: CBCentralManager?
    private var wantsScanning = false
    private var isSensing = false

    var onSensingChange: (@MainActor @Sendable (Bool) -> Void)? {
        get { shared.withLock { $0.onSensingChange } }
        set { shared.withLock { $0.onSensingChange = newValue } }
    }

    func start() {
        queue.async { [self] in
            wantsScanning = true
            if central == nil {
                // Asks for Bluetooth access the first time, if Settings hasn't.
                central = CBCentralManager(
                    delegate: self,
                    queue: queue,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
            } else {
                updateScanning()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wantsScanning = false
            updateScanning()
            central?.delegate = nil
            central = nil
        }
    }

    func setThreshold(_ dBm: Double) {
        shared.withLock { $0.tracker.threshold = dBm }
    }

    func nearCount(at now: Date) -> Int {
        shared.withLock { state in
            state.tracker.prune(at: now)
            return state.tracker.nearCount(at: now)
        }
    }

    private func updateScanning() {
        let shouldScan = wantsScanning && central?.state == .poweredOn
        if shouldScan, central?.isScanning == false {
            // Duplicates on: each advertisement is a fresh signal reading.
            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else if !shouldScan, central?.isScanning == true {
            central?.stopScan()
        }
        if !shouldScan {
            shared.withLock { $0.tracker.removeAll() }
        }
        guard shouldScan != isSensing else { return }
        isSensing = shouldScan
        if let onSensingChange = shared.withLock({ $0.onSensingChange }) {
            Task { @MainActor in onSensingChange(shouldScan) }
        }
    }

    // MARK: - CBCentralManagerDelegate (on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateScanning()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let kind = ContinuityAdvertisement(manufacturerData: data)?.kind
        else { return }
        let id = peripheral.identifier
        let now = Date()
        shared.withLock { $0.tracker.observe(id, kind: kind, rssi: RSSI.intValue, at: now) }
    }
}
