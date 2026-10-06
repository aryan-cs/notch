//
//  CalendarLayoutTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The calendar tab's shared rules: which event the up-next card features,
//  how events are grouped by day, and which days a month grid shows.
//

import AppKit
import XCTest
@testable import boringNotch

final class CalendarLayoutTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// Sunday, October 4 2026, at the given time.
    private func oct4(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 4 + dayOffset, hour: hour, minute: minute))!
    }

    private func event(
        _ title: String,
        _ start: Date,
        _ end: Date,
        allDay: Bool = false,
        type: EventType = .event(.accepted),
        id: String? = nil
    ) -> EventModel {
        EventModel(
            id: id ?? title,
            externalID: nil,
            start: start,
            end: end,
            title: title,
            location: nil,
            notes: nil,
            url: nil,
            isAllDay: allDay,
            type: type,
            calendar: CalendarModel(
                id: "cal", account: "me@example.com", accountID: "account", isGoogleAccount: true,
                title: "Work", color: .systemBlue, isSubscribed: false, isReminder: false
            ),
            participants: [],
            timeZone: nil,
            hasRecurrenceRules: false,
            priority: nil,
            meetingLink: nil
        )
    }

    // MARK: nextEvent

    func testNextEventPrefersMeetingInProgress() {
        let events = [
            event("Standup", oct4(14), oct4(14, 15)),
            event("Design review", oct4(13, 30), oct4(14, 30)),
        ]
        XCTAssertEqual(UpcomingEvents.nextEvent(in: events, now: oct4(14, 5))?.title, "Design review")
    }

    func testNextEventSkipsEndedAllDayRemindersAndDeclined() {
        let events = [
            event("Ended", oct4(9), oct4(10)),
            event("Birthday", oct4(0), oct4(0, dayOffset: 1), allDay: true),
            event("Reminder", oct4(15), oct4(15), type: .reminder(completed: false)),
            event("Declined", oct4(15), oct4(16), type: .event(.declined)),
            event("Gym", oct4(18), oct4(19)),
        ]
        XCTAssertEqual(UpcomingEvents.nextEvent(in: events, now: oct4(12))?.title, "Gym")
    }

    func testNoNextEventWhenDayIsDone() {
        XCTAssertNil(UpcomingEvents.nextEvent(in: [event("Ended", oct4(9), oct4(10))], now: oct4(12)))
    }

    // MARK: byDay

    func testByDayGroupsAndPutsAllDayFirst() {
        let events = [
            event("Lunch", oct4(12, 30), oct4(13, 30)),
            event("Birthday", oct4(0), oct4(0, dayOffset: 1), allDay: true),
            event("Design review", oct4(10, dayOffset: 1), oct4(11, dayOffset: 1)),
        ]
        let days = UpcomingEvents.byDay(events, from: oct4(8), days: 3, calendar: calendar)

        XCTAssertEqual(days.map(\.day), [oct4(0), oct4(0, dayOffset: 1), oct4(0, dayOffset: 2)])
        XCTAssertEqual(days[0].events.map(\.title), ["Birthday", "Lunch"])
        XCTAssertEqual(days[1].events.map(\.title), ["Design review"])
        XCTAssertTrue(days[2].events.isEmpty)
    }

    func testMultiDayEventAppearsOnEachDay() {
        let trip = event("Trip", oct4(0), oct4(0, dayOffset: 3), allDay: true)
        let days = UpcomingEvents.byDay([trip], from: oct4(0), days: 4, calendar: calendar)
        XCTAssertEqual(days.map { $0.events.count }, [1, 1, 1, 0])
    }

    func testZeroLengthReminderAtMidnightStaysOnItsDay() {
        let reminder = event("Pay rent", oct4(0, dayOffset: 1), oct4(0, dayOffset: 1), type: .reminder(completed: false))
        let days = UpcomingEvents.byDay([reminder], from: oct4(0), days: 2, calendar: calendar)
        XCTAssertEqual(days.map { $0.events.count }, [0, 1])
    }

    func testRecurringOccurrencesGetDistinctKeys() {
        let monday = event("Standup", oct4(14, dayOffset: 1), oct4(14, 15, dayOffset: 1), id: "series")
        let tuesday = event("Standup", oct4(14, dayOffset: 2), oct4(14, 15, dayOffset: 2), id: "series")
        XCTAssertNotEqual(monday.occurrenceKey, tuesday.occurrenceKey)
    }

    // MARK: Descriptions

    func testNotesDropGoogleMeetBoilerplateAndHTML() {
        let raw = """
        Weekly sync on <b>launch</b> plans.<br>Bring numbers.
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/abc-defg-hij
        Join by phone
        (US) +1 234-567-8900 PIN: 123456789
        """
        XCTAssertEqual(EventModel.readableNotes(raw), "Weekly sync on launch plans. Bring numbers.")
    }

    func testNotesThatAreOnlyALinkBecomeNil() {
        XCTAssertNil(EventModel.readableNotes("https://zoom.us/j/123456789"))
        XCTAssertNil(EventModel.readableNotes("   \n  "))
    }

    func testNotesDecodeEntities() {
        XCTAssertEqual(EventModel.readableNotes("Q&amp;A&nbsp;with the team"), "Q&A with the team")
    }

    // MARK: MiniMonth

    func testOctober2026GridStartingSunday() {
        // October 1 2026 is a Thursday: four leading September days, five weeks.
        let days = MiniMonth.days(for: oct4(12), firstWeekday: 1, calendar: calendar)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(calendar.component(.day, from: days[0]), 27)
        XCTAssertEqual(calendar.component(.day, from: days[4]), 1)
        XCTAssertEqual(calendar.component(.day, from: days[34]), 31)
    }

    func testGridStartingMondayShiftsLeadingDays() {
        let days = MiniMonth.days(for: oct4(12), firstWeekday: 2, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: days[0]), 28)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(days.count % 7, 0)
    }
}
