//
//  CalendarModel.swift
//  Calendr
//
//  Created by Paker on 31/12/20.
//  Original source: https://github.com/pakerwreah/Calendr
//

import Cocoa

struct CalendarModel: Equatable {
    let id: String
    let account: String
    /// Stable identifier of the account (`EKSource`) the calendar syncs from, used to
    /// group calendars by account. Local, subscribed and birthday calendars share
    /// `CalendarModel.otherAccountID`.
    let accountID: String
    /// Best-effort guess that the account is a Google account added in Internet Accounts.
    let isGoogleAccount: Bool
    let title: String
    let color: NSColor
    let isSubscribed: Bool
    let isReminder: Bool // true if this is a reminder calendar
}
