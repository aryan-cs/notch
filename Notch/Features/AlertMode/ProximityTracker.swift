//
//  ProximityTracker.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Turns a stream of advertisements into one number: how many personal
//  Apple devices are close right now. Each advertiser's signal strength is
//  smoothed over a couple of seconds, so a single strong packet from someone
//  walking past doesn't count.
//
//  Identifiers are the random ones CoreBluetooth assigns per Bluetooth
//  address, and Apple devices rotate their address about every 15 minutes,
//  so one device shows up as a series of identifiers. Nothing here tries to
//  follow a device across that: entries live in memory for seconds, the
//  guard compares counts rather than identities, and a newcomer that takes
//  over from an entry that just went quiet is treated as the same device.
//

import Defaults
import Foundation

/// How close a device has to come to count, as a threshold on its smoothed
/// signal strength. Rough distances for an iPhone in the open; a phone in a
/// pocket or behind a body reads closer to Low.
enum PresenceSensitivity: String, CaseIterable, Identifiable, Defaults.Serializable {
    /// About an arm's length.
    case low
    /// About 1.5 m.
    case medium
    /// About 2–3 m.
    case high

    var id: String { rawValue }

    /// dBm.
    var threshold: Double {
        switch self {
        case .low: -58
        case .medium: -65
        case .high: -72
        }
    }
}

struct ProximityTracker {
    struct Entry: Equatable {
        var kind: ContinuityAdvertisement.Kind
        /// Smoothed, in dBm.
        var rssi: Double
        var firstSeen: Date
        var lastSeen: Date
        var isNear: Bool
    }

    /// dBm a device's smoothed signal has to reach to count as near.
    var threshold: Double = PresenceSensitivity.medium.threshold
    /// A near device stays near until it drops this far below the threshold,
    /// so one hovering at the edge doesn't flicker in and out.
    var hysteresis: Double = 5
    /// Time constant of the smoothing.
    var smoothing: TimeInterval = 2
    /// A device only counts once it's been heard this long — someone walking
    /// past is gone first — and only while it's still being heard.
    var minimumAge: TimeInterval = 2
    var freshness: TimeInterval = 5
    /// Entries not heard for this long are forgotten.
    var expiry: TimeInterval = 10
    /// How long an entry has to be quiet before a newcomer can take its place.
    var rotationQuiet: TimeInterval = 1.5
    /// How far apart the two can be, in dBm, and still be one device.
    var rotationTolerance: Double = 12
    /// Bounds memory somewhere with hundreds of devices around.
    var capacity = 256

    private(set) var entries: [UUID: Entry] = [:]

    mutating func observe(_ id: UUID, kind: ContinuityAdvertisement.Kind, rssi: Int, at now: Date) {
        // CoreBluetooth reports 127 when it has no reading.
        guard rssi < 0, rssi > -127 else { return }
        let reading = Double(rssi)

        if var entry = entries[id] {
            let elapsed = max(0, now.timeIntervalSince(entry.lastSeen))
            entry.rssi += (1 - exp(-elapsed / smoothing)) * (reading - entry.rssi)
            entry.lastSeen = now
            entry.kind = kind
            entry.isNear = entry.rssi >= threshold - (entry.isNear ? hysteresis : 0)
            entries[id] = entry
            return
        }

        if entries.count >= capacity {
            prune(at: now)
            if entries.count >= capacity,
               let oldest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                entries[oldest] = nil
            }
        }
        entries[id] = Entry(kind: kind, rssi: reading, firstSeen: now, lastSeen: now, isNear: reading >= threshold)
    }

    mutating func prune(at now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= expiry }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Near devices still being heard, with each address rotation counted once.
    func nearCount(at now: Date) -> Int {
        let near = entries
            .filter { _, entry in
                entry.isNear
                    && entry.lastSeen.timeIntervalSince(entry.firstSeen) >= minimumAge
                    && now.timeIntervalSince(entry.lastSeen) <= freshness
            }
            .sorted { $0.value.lastSeen < $1.value.lastSeen }

        var successors = Set<UUID>()
        var replaced = 0
        for (id, old) in near where now.timeIntervalSince(old.lastSeen) >= rotationQuiet {
            // Something of the same kind, at about the same strength, that
            // started up as this one went quiet.
            let successor = near.first { candidate in
                candidate.key != id
                    && !successors.contains(candidate.key)
                    && candidate.value.kind == old.kind
                    && candidate.value.firstSeen >= old.lastSeen
                    && abs(candidate.value.rssi - old.rssi) <= rotationTolerance
            }
            if let successor {
                successors.insert(successor.key)
                replaced += 1
            }
        }
        return near.count - replaced
    }
}
