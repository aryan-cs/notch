//
//  NotchState.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Whether a notch is open, and which tab it shows.
//

import Defaults
import Foundation

enum NotchState {
    case closed
    case open
}

enum NotchTab {
    case home
    case calendar
    case shelf
    case clipboard
    case devices

    /// The pages that are turned on, in the order the header shows them:
    /// the tab bar on the left, then Devices on the right. Swiping sideways
    /// moves through them in this order.
    static var available: [NotchTab] {
        var tabs: [NotchTab] = [.home]
        if Defaults[.showCalendar] { tabs.append(.calendar) }
        if Defaults[.shelfEnabled] { tabs.append(.shelf) }
        if Defaults[.clipboardHistory] { tabs.append(.clipboard) }
        if Defaults[.showDevicesTab] { tabs.append(.devices) }
        return tabs
    }
}
