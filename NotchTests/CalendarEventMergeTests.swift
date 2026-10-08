//
//  CalendarEventMergeTests.swift
//  boringNotchTests
//

import AppKit
import XCTest

@testable import Notch

final class CalendarEventMergeTests: XCTestCase {

    private let personal = CalendarModel(
        id: "personal", account: "me@gmail.com", accountID: "google-personal", isGoogleAccount: true,
        title: "me@gmail.com", color: .systemBlue, isSubscribed: false, isReminder: false)
    private let work = CalendarModel(
        id: "work", account: "me@work.com", accountID: "google-work", isGoogleAccount: true,
        title: "me@work.com", color: .systemGreen, isSubscribed: false, isReminder: false)
    private let delegated = CalendarModel(
        id: "delegated", account: "boss@work.com", accountID: "google-delegate", isGoogleAccount: true,
        title: "boss@work.com", color: .systemOrange, isSubscribed: true, isReminder: false)
    private let icloud = CalendarModel(
        id: "icloud", account: "iCloud", accountID: "icloud", isGoogleAccount: false,
        title: "Home", color: .systemRed, isSubscribed: false, isReminder: false)

    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(
        _ id: String,
        externalID: String? = nil,
        at hour: Double = 9,
        hours: Double = 1,
        title: String? = nil,
        isAllDay: Bool = false,
        type: EventType = .event(.accepted),
        calendar: CalendarModel? = nil,
        meetingLink: MeetingLink? = nil
    ) -> EventModel {
        let start = day.addingTimeInterval(hour * 3600)
        return EventModel(
            id: id,
            externalID: externalID,
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            title: title ?? id,
            location: nil,
            notes: nil,
            url: nil,
            isAllDay: isAllDay,
            type: type,
            calendar: calendar ?? personal,
            participants: [],
            timeZone: nil,
            hasRecurrenceRules: false,
            priority: nil,
            meetingLink: meetingLink
        )
    }

    private func meet(_ code: String = "abc-defg-hij") -> MeetingLink {
        MeetingLink(url: URL(string: "https://meet.google.com/\(code)")!, provider: .googleMeet)
    }

    // MARK: - Order

    func testEventsFromSeveralAccountsInterleaveByStart() {
        let merged = EventModel.mergedForDisplay([
            event("work-11", at: 11, calendar: work),
            event("personal-8", at: 8),
            event("icloud-10", at: 10, calendar: icloud),
            event("work-9", at: 9, calendar: work),
        ])
        XCTAssertEqual(merged.map(\.id), ["personal-8", "work-9", "icloud-10", "work-11"])
    }

    func testAllDayItemsComeFirst() {
        let merged = EventModel.mergedForDisplay([
            event("early", at: -2, hours: 3),
            event("offsite", at: 0, hours: 24, isAllDay: true, calendar: work),
        ])
        XCTAssertEqual(merged.map(\.id), ["offsite", "early"])
    }

    func testTiesBreakByEndThenTitleThenCalendar() {
        let merged = EventModel.mergedForDisplay([
            event("long", at: 9, hours: 2),
            event("b", at: 9, title: "Standup", calendar: work),
            event("a", at: 9, title: "Standup", calendar: personal),
            event("c", at: 9, title: "Retro"),
        ])
        XCTAssertEqual(merged.map(\.id), ["c", "a", "b", "long"])
    }

    func testOrderDoesNotDependOnFetchOrder() {
        let events = [
            event("a", externalID: "uid-1", calendar: personal),
            event("b", externalID: "uid-1", calendar: work),
            event("c", at: 9, title: "a"),
            event("d", at: 0, hours: 24, isAllDay: true),
            event("e", at: 9, title: "a", calendar: work),
        ]
        let expected = EventModel.mergedForDisplay(events).map(\.id)
        XCTAssertEqual(EventModel.mergedForDisplay(events.reversed()).map(\.id), expected)
        XCTAssertEqual(EventModel.mergedForDisplay([events[3], events[1], events[4], events[0], events[2]]).map(\.id), expected)
    }

    // MARK: - Duplicates

    func testMeetingBetweenTwoAccountsShowsOnce() {
        let merged = EventModel.mergedForDisplay([
            event("in-personal", externalID: "uid-1", calendar: personal),
            event("in-work", externalID: "uid-1", calendar: work),
        ])
        XCTAssertEqual(merged.count, 1)
    }

    func testAcceptedCopyBeatsDeclinedCopy() {
        let merged = EventModel.mergedForDisplay([
            event("declined", externalID: "uid-1", type: .event(.declined), calendar: personal),
            event("accepted", externalID: "uid-1", type: .event(.accepted), calendar: work),
        ])
        XCTAssertEqual(merged.map(\.id), ["accepted"])
    }

    func testOwnCalendarBeatsDelegatedCopy() {
        let merged = EventModel.mergedForDisplay([
            event("delegate-copy", externalID: "uid-1", calendar: delegated),
            event("own-copy", externalID: "uid-1", calendar: work),
        ])
        XCTAssertEqual(merged.map(\.id), ["own-copy"])
    }

    func testCopyWithMeetingLinkWins() {
        let merged = EventModel.mergedForDisplay([
            event("no-link", externalID: "uid-1", calendar: personal),
            event("with-link", externalID: "uid-1", calendar: work, meetingLink: meet()),
        ])
        XCTAssertEqual(merged.map(\.id), ["with-link"])
    }

    func testRecurringOccurrencesStaySeparate() {
        let merged = EventModel.mergedForDisplay([
            event("morning", externalID: "series", at: 9),
            event("evening", externalID: "series", at: 18),
        ])
        XCTAssertEqual(merged.map(\.id), ["morning", "evening"])
    }

    func testRescheduledCopyIsNotMerged() {
        let merged = EventModel.mergedForDisplay([
            event("original", externalID: "uid-1", at: 9),
            event("moved", externalID: "uid-1", at: 10, calendar: work),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testEventsWithoutExternalIDAndRemindersAreNeverMerged() {
        let merged = EventModel.mergedForDisplay([
            event("a", externalID: nil),
            event("b", externalID: nil, calendar: work),
            event("c", externalID: "", calendar: icloud),
            event("r1", externalID: "rem", type: .reminder(completed: false)),
            event("r2", externalID: "rem", type: .reminder(completed: false), calendar: work),
        ])
        XCTAssertEqual(merged.count, 5)
    }

    // MARK: - Join URL

    func testGoogleMeetJoinURLUsesTheCalendarsAccount() throws {
        let url = try XCTUnwrap(event("m", calendar: work, meetingLink: meet()).meetingJoinURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "authuser" }?.value, "me@work.com")
    }

    func testDelegatedAndNonGoogleCalendarsKeepTheRawLink() {
        XCTAssertEqual(event("d", calendar: delegated, meetingLink: meet()).meetingJoinURL, meet().url)
        XCTAssertEqual(event("i", calendar: icloud, meetingLink: meet()).meetingJoinURL, meet().url)
        XCTAssertNil(event("none", calendar: work).meetingJoinURL)
    }
}
