//
//  CalendarAccountsTests.swift
//  boringNotchTests
//

import AppKit
import EventKit
import XCTest

@testable import Notch

final class CalendarAccountsTests: XCTestCase {

    private func calendar(
        _ id: String,
        title: String? = nil,
        account: String = "me@gmail.com",
        accountID: String = "google-personal",
        isGoogleAccount: Bool = true
    ) -> CalendarModel {
        CalendarModel(
            id: id,
            account: account,
            accountID: accountID,
            isGoogleAccount: isGoogleAccount,
            title: title ?? id,
            color: .systemBlue,
            isSubscribed: false,
            isReminder: false
        )
    }

    // MARK: - Grouping

    func testSameCalendarTitlesInTwoAccountsStaySeparate() {
        let groups = CalendarAccountGroup.grouped([
            calendar("p-holidays", title: "Holidays in United States"),
            calendar("w-holidays", title: "Holidays in United States", account: "me@work.com", accountID: "google-work"),
        ])
        XCTAssertEqual(groups.map(\.title), ["me@gmail.com", "me@work.com"])
        XCTAssertEqual(groups.map { $0.calendars.map(\.id) }, [["p-holidays"], ["w-holidays"]])
    }

    func testAccountsSortByTitleWithOtherLast() {
        let groups = CalendarAccountGroup.grouped([
            calendar("local", account: "Other", accountID: CalendarModel.otherAccountID, isGoogleAccount: false),
            calendar("work", account: "me@work.com", accountID: "google-work"),
            calendar("icloud", account: "iCloud", accountID: "icloud", isGoogleAccount: false),
            calendar("personal"),
        ])
        XCTAssertEqual(groups.map(\.title), ["iCloud", "me@gmail.com", "me@work.com", "Other"])
        XCTAssertTrue(groups.last?.isOther == true)
    }

    func testPrimaryCalendarLeadsThenAlphabetical() {
        let group = CalendarAccountGroup.grouped([
            calendar("tasks", title: "Team"),
            calendar("birthdays", title: "Birthdays"),
            calendar("primary", title: "Me@Gmail.com"),
            calendar("holidays", title: "Holidays in United States"),
        ]).first
        XCTAssertEqual(group?.calendars.map(\.id), ["primary", "birthdays", "holidays", "tasks"])
    }

    func testAccountsWithTheSameTitleAreNotMerged() {
        let groups = CalendarAccountGroup.grouped([
            calendar("a", account: "Google", accountID: "source-1"),
            calendar("b", account: "Google", accountID: "source-2"),
        ])
        XCTAssertEqual(groups.map(\.id), ["source-1", "source-2"])
    }

    func testGroupFlagsGoogleAccounts() {
        let groups = CalendarAccountGroup.grouped([
            calendar("personal"),
            calendar("icloud", account: "iCloud", accountID: "icloud", isGoogleAccount: false),
        ])
        XCTAssertEqual(groups.map(\.isGoogleAccount), [false, true])
    }

    // MARK: - Google detection

    func testGoogleAccountDetection() {
        XCTAssertTrue(CalendarModel.isLikelyGoogleAccount(sourceType: .calDAV, title: "me@gmail.com"))
        XCTAssertTrue(CalendarModel.isLikelyGoogleAccount(sourceType: .calDAV, title: "alex@company.com"))
        XCTAssertTrue(CalendarModel.isLikelyGoogleAccount(sourceType: .calDAV, title: "Google"))
        XCTAssertTrue(CalendarModel.isLikelyGoogleAccount(sourceType: .calDAV, title: "Work Gmail"))
        XCTAssertFalse(CalendarModel.isLikelyGoogleAccount(sourceType: .calDAV, title: "iCloud"))
        XCTAssertFalse(CalendarModel.isLikelyGoogleAccount(sourceType: .exchange, title: "me@company.com"))
        XCTAssertFalse(CalendarModel.isLikelyGoogleAccount(sourceType: .subscribed, title: "Google Holidays"))
        XCTAssertFalse(CalendarModel.isLikelyGoogleAccount(sourceType: .local, title: "On My Mac"))
    }

    func testEmailAddressShape() {
        XCTAssertTrue("me@gmail.com".isLikelyEmailAddress)
        XCTAssertTrue("first.last+tag@company.co.uk".isLikelyEmailAddress)
        XCTAssertFalse("Work".isLikelyEmailAddress)
        XCTAssertFalse("me@localhost".isLikelyEmailAddress)
        XCTAssertFalse("@gmail.com".isLikelyEmailAddress)
        XCTAssertFalse("me@@gmail.com".isLikelyEmailAddress)
        XCTAssertFalse("me @gmail.com".isLikelyEmailAddress)
        XCTAssertFalse("me@gmail.".isLikelyEmailAddress)
    }

    // MARK: - Selection

    func testIncludes() {
        XCTAssertTrue(CalendarSelectionState.all.includes("a"))
        XCTAssertTrue(CalendarSelectionState.selected(["a"]).includes("a"))
        XCTAssertFalse(CalendarSelectionState.selected(["a"]).includes("b"))
        XCTAssertFalse(CalendarSelectionState.excluded(["a"]).includes("a"))
        XCTAssertTrue(CalendarSelectionState.excluded(["a"]).includes("b"))
    }

    func testHidingAndReshowingReturnsToAll() {
        let known: Set = ["a", "b"]
        let hidden = CalendarSelectionState.all.setting(["a"], selected: false, knownCalendarIDs: known)
        XCTAssertEqual(hidden, .excluded(["a"]))
        XCTAssertEqual(hidden.setting(["a"], selected: true, knownCalendarIDs: known), .all)
    }

    func testCalendarsFromANewAccountAreShown() {
        let state = CalendarSelectionState.all.setting(["a"], selected: false, knownCalendarIDs: ["a", "b"])
        XCTAssertTrue(state.includes("new-google-calendar"))
    }

    func testHidingEverythingShowsNothing() {
        let known: Set = ["a", "b"]
        let state = CalendarSelectionState.all.setting(known, selected: false, knownCalendarIDs: known)
        XCTAssertFalse(state.includes("a"))
        XCTAssertFalse(state.includes("b"))
    }

    func testAccountToggleHidesAndShowsAllItsCalendars() {
        let known: Set = ["p1", "p2", "w1"]
        let hidden = CalendarSelectionState.excluded(["w1"]).setting(["p1", "p2"], selected: false, knownCalendarIDs: known)
        XCTAssertEqual(hidden, .excluded(["p1", "p2", "w1"]))
        XCTAssertEqual(hidden.setting(["p1", "p2"], selected: true, knownCalendarIDs: known), .excluded(["w1"]))
    }

    func testExclusionsForRemovedCalendarsAreKept() {
        let state = CalendarSelectionState.excluded(["gone"]).setting(["a"], selected: false, knownCalendarIDs: ["a", "b"])
        XCTAssertEqual(state, .excluded(["gone", "a"]))
    }

    // MARK: - Migration

    func testLegacyAllowListBecomesExclusionList() {
        let migrated = CalendarSelectionState.selected(["a", "b"]).migrated(knownCalendarIDs: ["a", "b", "c"])
        XCTAssertEqual(migrated, .excluded(["c"]))
        XCTAssertTrue(migrated.includes("added-later"))
    }

    func testLegacyAllowListDropsStaleIdentifiers() {
        let migrated = CalendarSelectionState.selected(["a", "stale"]).migrated(knownCalendarIDs: ["a", "b"])
        XCTAssertEqual(migrated, .excluded(["b"]))
    }

    func testLegacyAllowListWithNoSurvivingCalendarsShowsAll() {
        let migrated = CalendarSelectionState.selected(["old-1", "old-2"]).migrated(knownCalendarIDs: ["new-1"])
        XCTAssertEqual(migrated, .all)
    }

    func testLegacyAllowListCoveringEverythingBecomesAll() {
        XCTAssertEqual(CalendarSelectionState.selected(["a", "b"]).migrated(knownCalendarIDs: ["a", "b"]), .all)
    }

    func testMigrationWaitsForKnownCalendars() {
        XCTAssertEqual(CalendarSelectionState.selected(["a"]).migrated(knownCalendarIDs: []), .selected(["a"]))
        XCTAssertEqual(CalendarSelectionState.excluded(["a"]).migrated(knownCalendarIDs: ["b"]), .excluded(["a"]))
        XCTAssertEqual(CalendarSelectionState.all.migrated(knownCalendarIDs: ["b"]), .all)
    }

    func testTogglingMigratesLegacyState() {
        let state = CalendarSelectionState.selected(["a", "b"]).setting(["b"], selected: false, knownCalendarIDs: ["a", "b", "c"])
        XCTAssertEqual(state, .excluded(["b", "c"]))
    }

    func testTogglingLegacyStateWithoutKnownCalendarsEditsAllowList() {
        let state = CalendarSelectionState.selected(["a"]).setting(["b"], selected: true, knownCalendarIDs: [])
        XCTAssertEqual(state, .selected(["a", "b"]))
    }

    // MARK: - Stored format

    func testLegacyStoredValuesStillDecode() throws {
        let decoder = JSONDecoder()
        let all = try decoder.decode(CalendarSelectionState.self, from: Data(#"{"all":{}}"#.utf8))
        XCTAssertEqual(all, .all)
        let selected = try decoder.decode(CalendarSelectionState.self, from: Data(#"{"selected":{"_0":["a","b"]}}"#.utf8))
        XCTAssertEqual(selected, .selected(["a", "b"]))
    }

    func testExcludedRoundTrips() throws {
        let state = CalendarSelectionState.excluded(["a", "b"])
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(CalendarSelectionState.self, from: data), state)
    }
}
