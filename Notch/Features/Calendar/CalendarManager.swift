//
//  CalendarManager.swift
//  Notch
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

    private init() {
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
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all
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
            Log.calendar.debug("Current calendar authorization status: \(String(describing: status))")
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
            }
        case .restricted, .denied:
            Log.calendar.error("Calendar access denied or restricted")
        case .fullAccess:
            Log.calendar.debug("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            Log.calendar.debug("Write only")
        @unknown default:
            Log.calendar.debug("Unknown authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            Log.calendar.debug("Current reminder authorization status: \(String(describing: status))")
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
            Log.calendar.error("Reminder access denied or restricted")
        case .fullAccess:
            Log.calendar.debug("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            Log.calendar.debug("Write only")
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
    }
}
