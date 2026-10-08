//
//  Log.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Loggers for the app and its helper: one subsystem, one category per area,
//  so you can filter in Console.app or with
//  `log show --predicate 'subsystem == "theboringteam.boringnotch"'`.
//  Debug messages stay in memory; notice and above are kept.
//

import OSLog

enum Log {
    private static let subsystem = "theboringteam.boringnotch"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let music = Logger(subsystem: subsystem, category: "music")
    static let osd = Logger(subsystem: subsystem, category: "osd")
    static let xpc = Logger(subsystem: subsystem, category: "xpc")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let battery = Logger(subsystem: subsystem, category: "battery")
    static let webcam = Logger(subsystem: subsystem, category: "webcam")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let presence = Logger(subsystem: subsystem, category: "presence")
    static let faceUnlock = Logger(subsystem: subsystem, category: "faceUnlock")
    static let helper = Logger(subsystem: subsystem, category: "helper")
}
