//
//  NotchHelperService+AppleDevices.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Battery levels of nearby iPhones, iPads and watches, read by the bundled
//  notch-appledevices tool.
//

import Foundation

extension NotchHelperService {
    /// Battery levels for trusted iPhones and iPads (USB or Wi-Fi) and their
    /// paired watches, as JSON from the bundled `notch-appledevices` tool
    /// (libimobiledevice; see Tools/notch-appledevices). It runs here
    /// because the sandboxed app can't reach usbmuxd. Nil if it fails — the
    /// tool gives up on its own after 25 seconds.
    @objc func fetchAppleDevices(with reply: @escaping (Data?) -> Void) {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("AppleDevicesTools/bin/notch-appledevices"),
              FileManager.default.isExecutableFile(atPath: tool.path)
        else {
            reply(nil)
            return
        }
        let process = Process()
        process.executableURL = tool
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.helper.error("Couldn't run notch-appledevices: \(error.localizedDescription, privacy: .public)")
            reply(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            reply(process.terminationStatus == 0 ? data : nil)
        }
    }
}
