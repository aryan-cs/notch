//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?
    /// EventKit can fire EKEventStoreChanged in bursts during syncs; reloads
    /// coalesce so the UI refreshes once per burst instead of per notification.
    private var reloadTask: Task<Void, Never>?
    private var storeChangedSinceReload = false
    /// Bumped per event fetch so a slower, older fetch can't overwrite a newer one.
    private var eventsGeneration = 0

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleStoreReload()
            }
        }
    }

    /// Covers synced event edits as well as accounts and calendars being added or
    /// removed in Internet Accounts. A change that lands while a reload is pending or
    /// running triggers one more pass, so the end of a long sync isn't missed.
    private func scheduleStoreReload() {
        storeChangedSinceReload = true
        guard reloadTask == nil else { return }
        reloadTask = Task {
            defer { reloadTask = nil }
            while storeChangedSinceReload {
                storeChangedSinceReload = false
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await reloadCalendarAndReminderLists()
                await updateEvents()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        migrateCalendarSelectionIfNeeded()
        updateSelectedCalendars()
    }

    /// Moves a legacy allow-list selection to the exclusion model once calendars are
    /// known, so accounts added afterwards show up without visiting Settings.
    private func migrateCalendarSelectionIfNeeded() {
        let state = Defaults[.calendarSelectionState]
        let migrated = state.migrated(knownCalendarIDs: Set(allCalendars.map { $0.id }))
        guard migrated != state else { return }
        Log.calendar.info("Migrated calendar selection to the exclusion model")
        Defaults[.calendarSelectionState] = migrated
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            Log.calendar.debug("📅 Current calendar authorization status: \(String(describing: status))")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents()
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            Log.calendar.debug("Unknown authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            Log.calendar.debug("📅 Current reminder authorization status: \(String(describing: status))")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            Log.calendar.debug("Unknown authorization status")
        }
    }

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        let selectionState = Defaults[.calendarSelectionState]
        selectedCalendars = allCalendars.filter { selectionState.includes($0.id) }
        selectedCalendarIDs = Set(selectedCalendars.map { $0.id })
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        await setCalendarsSelected([calendar], isSelected: isSelected)
    }

    /// Shows or hides several calendars at once, e.g. every calendar of an account.
    func setCalendarsSelected(_ calendars: [CalendarModel], isSelected: Bool) async {
        Defaults[.calendarSelectionState] = Defaults[.calendarSelectionState].setting(
            calendars.map { $0.id },
            selected: isSelected,
            knownCalendarIDs: Set(allCalendars.map { $0.id })
        )
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    /// Refetches the selected day's events from every selected calendar, merged into
    /// one list with cross-calendar duplicates collapsed.
    private func updateEvents() async {
        eventsGeneration += 1
        let generation = eventsGeneration
        let calendarIDs = selectedCalendars.map { $0.id }
        // The service reads an empty list as "all calendars".
        guard !calendarIDs.isEmpty else {
            events = []
            return
        }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        guard generation == eventsGeneration else { return }
        self.events = EventModel.mergedForDisplay(eventsResult)
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        await updateEvents()
    }
}
