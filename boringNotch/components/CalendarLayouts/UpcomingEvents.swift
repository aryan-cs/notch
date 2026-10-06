//
//  UpcomingEvents.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Data for the calendar tab's layouts (up next, month and agenda,
//  multi-day). CalendarManager loads one day at a time for the classic view;
//  these layouts need a span of days, so they fetch their own range through
//  the same CalendarService, honoring the same calendar selection and event
//  filters. The "what's next" and day-grouping rules are plain functions so
//  they can be unit tested.
//

import Combine
import Defaults
import EventKit
import Foundation

/// One day's events, as the layouts list them.
struct CalendarDay: Identifiable, Equatable {
    let day: Date
    let events: [EventModel]

    var id: Date { day }
}

enum UpcomingEvents {
    /// The event the up-next card features: the earliest timed event that
    /// hasn't ended, so a meeting in progress stays up until it's over.
    /// All-day events, reminders and declined invitations are skipped.
    static func nextEvent(in events: [EventModel], now: Date) -> EventModel? {
        events
            .filter { $0.type.isEvent && !$0.isAllDay && $0.end > now && $0.attendance != .declined }
            .min { $0.start < $1.start }
    }

    /// Events overlapping each of `days` days starting at `start`'s day, so an
    /// event spanning several days appears on each of them. All-day events
    /// come first within a day, then by start time.
    static func byDay(
        _ events: [EventModel],
        from start: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [CalendarDay] {
        let firstDay = calendar.startOfDay(for: start)
        return (0..<max(days, 0)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            // `start >= day` keeps zero-length items (reminders due at a
            // moment) that `end > day` alone would drop at midnight.
            let dayEvents = events
                .filter { $0.start < nextDay && ($0.end > day || $0.start >= day) }
                .sorted { lhs, rhs in
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    return lhs.start < rhs.start
                }
            return CalendarDay(day: day, events: dayEvents)
        }
    }
}

extension EventModel {
    /// Recurring events share an `id` across occurrences, so views key rows
    /// by occurrence instead.
    var occurrenceKey: String { "\(id)@\(start.timeIntervalSinceReferenceDate)" }
}

/// Loads events for a date range and keeps them current as calendars change.
@MainActor
final class UpcomingEventsModel: ObservableObject {
    @Published private(set) var events: [EventModel] = []

    private let service = CalendarService()
    private var range: DateInterval?
    private var loadTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // @Published fires before the new value is stored, so the reload
        // takes the emitted selection rather than reading the property.
        CalendarManager.shared.$selectedCalendarIDs
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ids in self?.reload(calendarIDs: ids) }
            .store(in: &cancellables)

        Defaults.publisher(keys: .hideAllDayEvents, .hideCompletedReminders, .hideDeclinedEvents, options: [])
            .sink { [weak self] in
                Task { @MainActor in self?.reload() }
            }
            .store(in: &cancellables)
    }

    func load(from start: Date, days: Int) {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: days, to: first) ?? first
        let newRange = DateInterval(start: first, end: end)
        guard newRange != range else { return }
        range = newRange
        reload()
    }

    private func reload(calendarIDs: Set<String>? = nil) {
        guard let range else { return }
        loadTask?.cancel()
        let ids = calendarIDs ?? CalendarManager.shared.selectedCalendarIDs
        // CalendarService reads an empty list as "every calendar". Empty here
        // means nothing is selected, or calendars haven't loaded yet (the
        // selection publishes again once they have) — show nothing either way.
        guard !ids.isEmpty else {
            events = []
            return
        }
        loadTask = Task {
            let fetched = await service.events(from: range.start, to: range.end, calendars: Array(ids))
            guard !Task.isCancelled else { return }
            // Same treatment as the classic list: duplicates across accounts
            // collapsed, then the user's hide filters.
            events = EventListView.filteredEvents(events: EventModel.mergedForDisplay(fetched))
        }
    }
}
