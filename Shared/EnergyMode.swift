//
//  EnergyMode.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Mac's energy mode, as in the system Battery menu's Energy Mode section
//  (`pmset powermode`). The helper reads it; BatteryMenu shows it.
//

import Foundation

enum EnergyMode: Int, Codable, CaseIterable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2
}

struct EnergyModeStatus: Codable, Equatable {
    /// The mode for the power source in use right now.
    let mode: EnergyMode
    /// Only some MacBook Pros offer High Power.
    let highPowerSupported: Bool
}
