//
//  CalendarSelectionState.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Which calendars the notch shows, as saved in settings.
//

import Defaults
import Foundation

/// Which calendars (keyed by `calendarIdentifier`) the notch shows.
enum CalendarSelectionState: Codable, Equatable, Defaults.Serializable {
    case all
    /// Legacy allow-list. Calendars that appear later (e.g. a newly added Google
    /// account) stay hidden, so it's migrated to `.excluded` once calendars load.
    case selected(Set<String>)
    /// Everything except these calendars, so new accounts and calendars show up
    /// without a trip to Settings.
    case excluded(Set<String>)
}
