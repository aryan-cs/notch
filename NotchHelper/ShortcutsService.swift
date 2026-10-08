//
//  ShortcutsService.swift
//  BoringNotchXPCHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Runs the presence guard's Focus shortcuts with `/usr/bin/shortcuts`,
//  which the sandboxed app can't (it can't reach the Shortcuts service).
//  Only the FocusShortcut names are ever run, and listing reports only which
//  of those exist — the rest of the user's shortcuts never leave here.
//

import Foundation

enum ShortcutsService {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// True if the shortcut ran and finished without an error.
    static func run(_ shortcut: FocusShortcut) -> Bool {
        shortcuts(["run", shortcut.rawValue], timeout: 30)?.status == 0
    }

    /// Which FocusShortcut names exist. Nil if `shortcuts list` failed.
    static func installed() -> [String]? {
        guard let result = shortcuts(["list"], timeout: 15), result.status == 0 else { return nil }
        let names = Set(
            String(decoding: result.output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        return FocusShortcut.allCases.map(\.rawValue).filter(names.contains)
    }

    private static func shortcuts(_ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[boringNotch] couldn't run shortcuts: %@", error.localizedDescription)
            return nil
        }
        // A shortcut waiting on something that never comes shouldn't hold
        // the reply forever.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data)
    }
}
