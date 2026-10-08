//
//  CalendarPreferences.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Calendar options from Settings → Calendar.
//

import Defaults
import Foundation

/// How the calendar tab lays out events (Settings → Calendar).
enum CalendarLayout: String, CaseIterable, Identifiable, Defaults.Serializable {
    case upNext
    case monthAgenda
    case multiDay

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .upNext:
            return String(localized: "Up next", comment: "Calendar layout: next event featured, rest of the week beside it")
        case .monthAgenda:
            return String(localized: "Month and agenda", comment: "Calendar layout: mini month next to an agenda list")
        case .multiDay:
            return String(localized: "Multi-day", comment: "Calendar layout: one column per day")
        }
    }
}

enum WeekStartDay: String, CaseIterable, Identifiable, Defaults.Serializable {
    case system
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }

    /// Calendar.firstWeekday convention: 1 = Sunday … 7 = Saturday
    var firstWeekday: Int {
        switch self {
        case .system: return Calendar.current.firstWeekday
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    /// Display name. Specific weekdays use the system's localized weekday names
    /// (Apple-provided via Calendar — no custom strings). The system option shows
    /// the resolved first weekday in parentheses, mirroring the macOS Calendar app.
    var localizedString: String {
        let symbols = Calendar.current.weekdaySymbols  // localized full names; index 0 = Sunday
        guard !symbols.isEmpty else { return rawValue }
        if self == .system {
            let systemName = symbols[(Calendar.current.firstWeekday - 1) % symbols.count]
            let label = NSLocalizedString("System Setting", comment: "Week starts on: follow the macOS system setting")
            return "\(label) (\(systemName))"
        }
        return symbols[(firstWeekday - 1) % symbols.count]
    }
}
