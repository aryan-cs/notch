//
//  EventModel.swift
//  Notch
//
//  Created by Paker on 24/12/20.
//  Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 2025-05-18.
//

import Foundation

struct EventModel: Equatable, Identifiable {
    let id: String
    /// The item's external identifier (the iCalendar UID for CalDAV accounts such as
    /// Google). Every copy of one event shares it, whichever calendar holds the copy.
    let externalID: String?
    let start: Date
    let end: Date
    let title: String
    let location: String?
    let notes: String?
    let url: URL?
    let isAllDay: Bool
    let type: EventType
    let calendar: CalendarModel
    let participants: [Participant]
    let timeZone: TimeZone?
    let hasRecurrenceRules: Bool
    let priority: Priority?
    /// Video-meeting join link recovered from the event's own fields, if any.
    /// Resolved once at fetch time — never on the view path.
    let meetingLink: MeetingLink?
}

enum AttendanceStatus: Comparable {
    case accepted
    case maybe
    case pending
    case declined
    case unknown

    private var comparisonValue: Int {
        switch self {
        case .accepted: return 1
        case .maybe: return 2
        case .declined: return 3
        case .pending: return 4
        case .unknown: return 5
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.comparisonValue < rhs.comparisonValue
    }
}

enum EventType: Equatable {
    case event(AttendanceStatus)
    case birthday
    case reminder(completed: Bool)
}

extension EventType {
    var isEvent: Bool { if case .event = self { return true } else { return false } }
    var isReminder: Bool { if case .reminder = self { return true } else { return false } }
}

extension EventModel {

    var attendance: AttendanceStatus { if case .event(let attendance) = type { return attendance } else { return .unknown } }

    /// URL to open when joining the meeting. Google Meet links on a Google account's
    /// calendar carry that account as `authuser`, so Meet opens in the right account
    /// when the browser is signed in to several.
    var meetingJoinURL: URL? {
        guard let meetingLink else { return nil }
        guard calendar.isGoogleAccount, !calendar.isSubscribed else { return meetingLink.url }
        return meetingLink.joinURL(googleAccount: calendar.account)
    }

    func calendarAppURL() -> URL? {
        guard let id = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        guard !type.isReminder else {
            return URL(string: "x-apple-reminderkit://remcdreminder/\(id)")
        }

        let date: String
        if hasRecurrenceRules {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            if !isAllDay {
                formatter.timeZone = .init(secondsFromGMT: 0)
            }
            if let formattedDate = formatter.string(for: start) {
                date = "/\(formattedDate)"
            } else {
                return nil
            }
        } else {
            date =  ""
        }
        return URL(string: "ical://ekevent\(date)/\(id)?method=show&options=more")
    }
}

// MARK: - Display order

extension EventModel {
    /// Orders events for the list and collapses copies of one event held by several
    /// calendars (a meeting between two of your Google accounts, or a colleague's
    /// calendar you can also see) into a single row.
    ///
    /// Copies match on external identifier plus start and end, so separate occurrences
    /// of a recurring event stay separate. A copy you haven't declined beats a declined
    /// one, your own calendar beats a subscribed or delegated one, and a copy with a
    /// meeting link beats one without.
    static func mergedForDisplay(_ events: [EventModel]) -> [EventModel] {
        var merged: [EventModel] = []
        var indexByKey: [DuplicateKey: Int] = [:]
        for event in events {
            guard let key = DuplicateKey(event) else {
                merged.append(event)
                continue
            }
            if let index = indexByKey[key] {
                if event.isPreferredCopy(over: merged[index]) {
                    merged[index] = event
                }
            } else {
                indexByKey[key] = merged.count
                merged.append(event)
            }
        }
        return merged.sorted(by: displayOrder)
    }

    /// All-day items first, then by start, end and title. Calendar and item identifiers
    /// break the remaining ties so rows don't reshuffle between refreshes.
    static func displayOrder(_ lhs: EventModel, _ rhs: EventModel) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if lhs.calendar.id != rhs.calendar.id { return lhs.calendar.id < rhs.calendar.id }
        return lhs.id < rhs.id
    }

    private struct DuplicateKey: Hashable {
        let externalID: String
        let start: Date
        let end: Date

        init?(_ event: EventModel) {
            guard !event.type.isReminder, let externalID = event.externalID, !externalID.isEmpty else {
                return nil
            }
            self.externalID = externalID
            self.start = event.start
            self.end = event.end
        }
    }

    private func isPreferredCopy(over other: EventModel) -> Bool {
        let isDeclined = attendance == .declined
        if isDeclined != (other.attendance == .declined) { return !isDeclined }
        if calendar.isSubscribed != other.calendar.isSubscribed { return !calendar.isSubscribed }
        let hasLink = meetingLink != nil
        if hasLink != (other.meetingLink != nil) { return hasLink }
        return calendar.id < other.calendar.id
    }
}

struct Participant: Hashable {
    let name: String
    let status: AttendanceStatus
    let isOrganizer: Bool
    let isCurrentUser: Bool
}

enum Priority {
    case high
    case medium
    case low
}
