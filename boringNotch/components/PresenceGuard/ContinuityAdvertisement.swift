//
//  ContinuityAdvertisement.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Apple's Continuity messages, read from the manufacturer data of a
//  Bluetooth LE advertisement: company ID 0x004C, then type-length-value
//  messages. iPhones, iPads, Watches and Macs send Nearby Info while awake;
//  AirPods send Proximity Pairing while out of their case. None of this is
//  documented (the type list follows the furiousMAC continuity research), so
//  parsing is defensive: a message that runs past the data ends the walk.
//

import Foundation

struct ContinuityAdvertisement: Equatable {
    struct Message: Equatable {
        let type: UInt8
        let payload: Data
    }

    /// The message types this reads. Others are parsed but ignored.
    enum MessageType: UInt8 {
        case iBeacon = 0x02
        case airPrint = 0x03
        case airDrop = 0x05
        case homeKit = 0x06
        case proximityPairing = 0x07
        case airPlayTarget = 0x09
        case magicSwitch = 0x0B
        case handoff = 0x0C
        case nearbyAction = 0x0F
        case nearbyInfo = 0x10
        case findMy = 0x12
    }

    /// What kind of thing a person might be carrying, for the proximity
    /// count. Beacons, printers, Apple TVs, HomeKit accessories and Find My
    /// tags aren't counted: they don't walk up to your desk on their own.
    enum Kind: Equatable {
        /// iPhone, iPad, Watch or Mac.
        case personal
        /// AirPods or Beats.
        case audio
    }

    static let appleCompanyID: UInt16 = 0x004C
    /// More than any real advertisement carries; stops a hostile one early.
    private static let maximumMessages = 8

    let messages: [Message]

    /// Nil unless the data is Apple's and holds at least one whole message.
    init?(manufacturerData data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == Self.appleCompanyID
        else { return nil }

        var messages: [Message] = []
        var index = 2
        while index + 2 <= bytes.count, messages.count < Self.maximumMessages {
            let length = Int(bytes[index + 1])
            let start = index + 2
            guard start + length <= bytes.count else { break }
            messages.append(Message(type: bytes[index], payload: Data(bytes[start..<start + length])))
            index = start + length
        }
        guard !messages.isEmpty else { return nil }
        self.messages = messages
    }

    func contains(_ type: MessageType) -> Bool {
        messages.contains { $0.type == type.rawValue }
    }

    /// Nil for anything that isn't a personal device.
    var kind: Kind? {
        if contains(.proximityPairing) { return .audio }
        let personal: [MessageType] = [.nearbyInfo, .handoff, .nearbyAction, .magicSwitch, .airDrop]
        return personal.contains(where: contains) ? .personal : nil
    }
}
