//
//  NotchDevicesTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  How the devices tab merges Bluetooth devices with audio outputs, orders
//  them, recognizes device types, and reads battery values.
//

import CoreAudio
import XCTest
@testable import boringNotch

final class NotchDevicesTests: XCTestCase {

    private func bluetooth(
        _ name: String,
        address: String,
        connected: Bool,
        major: UInt32 = 0x04,
        minor: UInt32 = 0x05,
        battery: DeviceBattery = DeviceBattery()
    ) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(address: address, name: name, isConnected: connected, majorClass: major, minorClass: minor, battery: battery)
    }

    private let speakers = AudioOutputDevice(id: 10, name: "MacBook Pro Speakers", transportType: kAudioDeviceTransportTypeBuiltIn)
    private let jbl = AudioOutputDevice(id: 20, name: "JBL Go 3", transportType: kAudioDeviceTransportTypeBluetooth)

    func testConnectedBluetoothDeviceMergesWithItsOutput() {
        let devices = NotchDevices.merge(
            bluetooth: [bluetooth("JBL Go 3", address: "aa-bb", connected: true)],
            outputs: [speakers, jbl],
            activeOutputID: 10
        )
        XCTAssertEqual(devices.map(\.name), ["MacBook Pro Speakers", "JBL Go 3"])
        XCTAssertEqual(devices[1].audioOutputID, 20)
        XCTAssertNotNil(devices[1].bluetoothAddress)
    }

    func testOrderIsOutputThenConnectedThenOutputsThenDisconnected() {
        let devices = NotchDevices.merge(
            bluetooth: [
                bluetooth("JBL GO 2", address: "11", connected: false),
                bluetooth("JBL Go 3", address: "22", connected: true),
                bluetooth("Magic Keyboard", address: "33", connected: true, major: 0x05, minor: 0x10),
            ],
            outputs: [speakers, jbl],
            activeOutputID: 20
        )
        XCTAssertEqual(devices.map(\.name), ["JBL Go 3", "Magic Keyboard", "MacBook Pro Speakers", "JBL GO 2"])
    }

    func testDisconnectedDeviceDoesNotClaimAnOutput() {
        let devices = NotchDevices.merge(
            bluetooth: [bluetooth("JBL Go 3", address: "aa", connected: false)],
            outputs: [jbl],
            activeOutputID: 0
        )
        XCTAssertEqual(devices.count, 2)
        XCTAssertNil(devices.first { $0.bluetoothAddress != nil }?.audioOutputID)
    }

    func testKinds() {
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("AirPods Pro", address: "", connected: true, minor: 0x06)), .earbuds("airpodspro"))
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("JBL Go 3", address: "", connected: true, minor: 0x05)), .speaker)
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("Sony WH-1000XM5", address: "", connected: true, minor: 0x06)), .headphones)
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("Magic Trackpad", address: "", connected: true, major: 0x05, minor: 0x20)), .trackpad)
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("Keychron K2", address: "", connected: true, major: 0x05, minor: 0x10)), .keyboard)
        XCTAssertEqual(NotchDevices.kind(for: bluetooth("Ring", address: "", connected: true, major: 0x1F, minor: 0)), .other)
    }

    func testSpeakerClasses() {
        XCTAssertEqual(NotchDevices.isSpeaker(major: 0x04, minor: 0x05), true)   // loudspeaker
        XCTAssertEqual(NotchDevices.isSpeaker(major: 0x04, minor: 0x07), true)   // portable audio
        XCTAssertEqual(NotchDevices.isSpeaker(major: 0x04, minor: 0x06), false)  // headphones
        XCTAssertEqual(NotchDevices.isSpeaker(major: 0x04, minor: 0x01), false)  // headset
        XCTAssertNil(NotchDevices.isSpeaker(major: 0x05, minor: 0x05))           // not audio
    }

    func testBluetoothAddressFromAudioUID() {
        XCTAssertEqual(NotchDevices.bluetoothAddress(fromAudioUID: "AC-12-2F-00-11-22:output"), "AC-12-2F-00-11-22")
        XCTAssertNil(NotchDevices.bluetoothAddress(fromAudioUID: "BuiltInSpeakerDevice"))
    }

    func testAddressesCompareAcrossFormats() {
        XCTAssertEqual(NotchDevices.normalizedAddress("AA-BB-CC-DD-EE-FF"), NotchDevices.normalizedAddress("aa:bb:cc:dd:ee:ff"))
    }

    func testAppleDeviceReadingsDecode() throws {
        let json = #"[{"id":"0000-1","name":"Alex's iPhone","model":"iPhone15,2","class":"iPhone","battery":8,"charging":true},{"id":"w1","name":"Alex's Watch","model":"Watch7,1","class":"Watch","battery":64,"charging":false,"parent":"Alex's iPhone"}]"#
        let readings = try XCTUnwrap(AppleDeviceReading.decodeList(Data(json.utf8)))
        XCTAssertEqual(readings.map(\.deviceClass), ["iPhone", "Watch"])
        XCTAssertEqual(readings[1].parent, "Alex's iPhone")
        XCTAssertNil(AppleDeviceReading.decodeList(Data("not json".utf8)))
    }

    func testAppleDevicesJoinConnectedDevicesAndReplaceTheirBluetoothTwin() {
        let phone = AppleDeviceReading(id: "1", name: "Sam’s iPhone", model: "iPhone15,2", deviceClass: "iPhone", battery: 8, charging: true, parent: nil)
        let devices = NotchDevices.merge(
            bluetooth: [
                bluetooth("Sam’s iPhone", address: "11", connected: false, major: 0x02, minor: 0x03),
                bluetooth("JBL GO 2", address: "22", connected: false),
            ],
            outputs: [speakers],
            activeOutputID: 10,
            appleDevices: [phone]
        )
        XCTAssertEqual(devices.map(\.name), ["MacBook Pro Speakers", "Sam’s iPhone", "JBL GO 2"])
        XCTAssertEqual(devices[1].kind, .phone)
        XCTAssertEqual(devices[1].battery, DeviceBattery(single: 8, isCharging: true))
    }

    func testMacBookSpeakersCarryTheMacsBattery() {
        let devices = NotchDevices.merge(
            bluetooth: [],
            outputs: [speakers, jbl],
            activeOutputID: 20,
            macBattery: DeviceBattery(single: 54, isCharging: true)
        )
        XCTAssertEqual(devices.first { $0.name == "MacBook Pro Speakers" }?.battery, DeviceBattery(single: 54, isCharging: true))
        XCTAssertEqual(devices.first { $0.name == "JBL Go 3" }?.battery, DeviceBattery())
    }

    func testUnreachablePhoneKeepsItsCardWithLastLevel() {
        let phone = AppleDeviceReading(id: "1", name: "Sam’s iPhone", model: "iPhone15,2", deviceClass: "iPhone", battery: 62, charging: true, parent: nil)
        var known = KnownAppleDevices()
        let seen = Date(timeIntervalSince1970: 1_000_000)
        known.record([phone], at: seen)
        known.record([], at: seen.addingTimeInterval(600))
        let unreachable = known.unreachable(excluding: [])
        XCTAssertEqual(unreachable.map(\.lastSeen), [seen])

        let devices = NotchDevices.merge(
            bluetooth: [bluetooth("Sam’s iPhone", address: "11", connected: false, major: 0x02, minor: 0x03)],
            outputs: [speakers],
            activeOutputID: 10,
            unreachableAppleDevices: unreachable
        )
        XCTAssertEqual(devices.map(\.name), ["MacBook Pro Speakers", "Sam’s iPhone"])
        XCTAssertFalse(devices[1].isConnected)
        XCTAssertEqual(devices[1].lastSeen, seen)
        XCTAssertEqual(devices[1].battery, DeviceBattery(single: 62))   // no stale "charging"
    }

    func testSerialNumbersReachTheCards() throws {
        let json = #"[{"id":"1","name":"Phone","model":"iPhone15,2","class":"iPhone","battery":74,"charging":true,"serial":"CRW1625G9W"}]"#
        let readings = try XCTUnwrap(AppleDeviceReading.decodeList(Data(json.utf8)))
        XCTAssertEqual(readings.first?.serial, "CRW1625G9W")
        let devices = NotchDevices.merge(bluetooth: [], outputs: [], activeOutputID: 0, appleDevices: readings)
        XCTAssertEqual(devices.first?.serialNumber, "CRW1625G9W")

        // Readings from before serials were reported still decode.
        let old = #"[{"id":"1","name":"Phone","model":"iPhone15,2","class":"iPhone","battery":74,"charging":true}]"#
        XCTAssertNil(try XCTUnwrap(AppleDeviceReading.decodeList(Data(old.utf8))).first?.serial)
    }

    func testKnownDevicesAreForgottenAfterAWeek() {
        let phone = AppleDeviceReading(id: "1", name: "Phone", model: "iPhone15,2", deviceClass: "iPhone", battery: 50, charging: false, parent: nil)
        var known = KnownAppleDevices()
        let seen = Date(timeIntervalSince1970: 1_000_000)
        known.record([phone], at: seen)
        known.record([], at: seen.addingTimeInterval(KnownAppleDevices.retention + 1))
        XCTAssertTrue(known.entries.isEmpty)
    }

    func testOnlyRealPercentagesCount() {
        XCTAssertEqual(NotchDevices.validLevel(NSNumber(value: 80)), 80)
        XCTAssertNil(NotchDevices.validLevel(NSNumber(value: 0)))
        XCTAssertNil(NotchDevices.validLevel(NSNumber(value: 255)))
        XCTAssertNil(NotchDevices.validLevel("80"))
        XCTAssertNil(NotchDevices.validLevel(nil))
    }
}
