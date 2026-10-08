//
//  NotchState.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Whether a notch is open, and which tab it shows.
//

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
}
