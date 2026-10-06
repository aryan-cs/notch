//
//  EnergyModeService.swift
//  BoringNotchXPCHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reads the Mac's energy mode with `pmset -g`, which needs no special
//  access (the sandboxed app can't run pmset itself).
//

import Foundation

enum EnergyModeService {
    static func status() -> EnergyModeStatus? {
        guard let settings = pmset(["-g"]) else { return nil }
        var values: [String: String] = [:]
        for line in settings.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2 { values[String(fields[0])] = String(fields[1]) }
        }
        // Macs with High Power report `powermode` (0, 1, 2); others only
        // `lowpowermode` (0, 1).
        let mode: EnergyMode
        if let raw = values["powermode"].flatMap({ Int($0) }), let parsed = EnergyMode(rawValue: raw) {
            mode = parsed
        } else {
            mode = values["lowpowermode"] == "1" ? .lowPower : .automatic
        }
        return EnergyModeStatus(mode: mode, highPowerSupported: supportsHighPower())
    }

    private static func supportsHighPower() -> Bool {
        pmset(["-g", "cap"])?
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "highpowermode" } ?? false
    }

    /// pmset's output, or nil if it failed.
    private static func pmset(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
