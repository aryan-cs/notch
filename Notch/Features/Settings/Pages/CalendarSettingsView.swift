//
//  CalendarSettingsView.swift
//  Notch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import EventKit
import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.calendarLayout) var calendarLayout
    @Default(.weekStartDay) var weekStartDay

    private var hasGoogleCalendars: Bool {
        calendarManager.eventCalendars.contains { $0.isGoogleAccount }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showCalendar) {
                    Text("Show calendar")
                }
                Picker("Layout", selection: $calendarLayout) {
                    ForEach(CalendarLayout.allCases) { layout in
                        Text(layout.localizedName).tag(layout)
                    }
                }
                if calendarLayout == .monthAgenda {
                    Picker("Week starts on", selection: $weekStartDay) {
                        ForEach(WeekStartDay.allCases) { day in
                            Text(day.localizedString).tag(day)
                        }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Choose how the calendar is displayed in the notch.")
            }

            Section {
                Defaults.Toggle(key: .hideCompletedReminders) {
                    Text("Hide completed reminders")
                }
                Defaults.Toggle(key: .hideAllDayEvents) {
                    Text("Hide all-day events")
                }
                Defaults.Toggle(key: .hideDeclinedEvents) {
                    Text("Hide declined events")
                }
                Defaults.Toggle(key: .showFullEventTitles) {
                    Text("Always show full event titles")
                }
                Defaults.Toggle(key: .joinMeetingOnEventTap) {
                    Text("Join meeting when tapping an event")
                }
            } header: {
                Text("Events")
            }

            Section {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    PermissionDeniedNotice(
                        message: "Calendar access is denied. Please enable it in System Settings.",
                        buttonTitle: "Open Calendar Settings",
                        privacyPane: .calendars
                    )
                } else {
                    if !hasGoogleCalendars {
                        GoogleAccountsHint()
                    }
                    CalendarList(
                        calendars: calendarManager.eventCalendars,
                        calendarManager: calendarManager,
                        isEnabled: showCalendar
                    )
                }
            } header: {
                Text("Calendars")
            } footer: {
                if calendarManager.calendarAuthorizationStatus == .fullAccess && hasGoogleCalendars {
                    Text("Add more Google accounts in System Settings → Internet Accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    PermissionDeniedNotice(
                        message: "Reminder access is denied. Please enable it in System Settings.",
                        buttonTitle: "Open Reminder Settings",
                        privacyPane: .reminders
                    )
                } else {
                    CalendarList(
                        calendars: calendarManager.reminderLists,
                        calendarManager: calendarManager,
                        isEnabled: showCalendar
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }
}

/// The Privacy & Security panes relevant to calendar data.
private enum PrivacyPane {
    case calendars
    case reminders

    /// System Settings deep link for the pane.
    var settingsURL: URL? {
        switch self {
        case .calendars:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .reminders:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        }
    }
}

/// An access-denied explanation with a shortcut to the relevant pane of
/// System Settings → Privacy & Security.
private struct PermissionDeniedNotice: View {
    let message: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let privacyPane: PrivacyPane

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding()
            Button(buttonTitle) {
                if let settingsURL = privacyPane.settingsURL {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shown when no Google account is found. EventKit only sees Google calendars from
/// accounts added in System Settings, so that's where the user has to go.
private struct GoogleAccountsHint: View {
    private static let internetAccountsURL = URL(
        string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("No Google calendars found")
                    .font(.headline)
                Text("Add your Google accounts in System Settings → Internet Accounts to see their calendars here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Internet Accounts") {
                if let url = Self.internetAccountsURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// A selectable list of calendars (or reminder lists) grouped by account, with
/// calendar-colored toggles. Shared by the Calendars and Reminders sections.
private struct CalendarList: View {
    let calendars: [CalendarModel]
    @ObservedObject var calendarManager: CalendarManager
    let isEnabled: Bool

    var body: some View {
        ForEach(CalendarAccountGroup.grouped(calendars)) { group in
            AccountToggle(group: group, calendarManager: calendarManager)
                .disabled(!isEnabled)

            ForEach(group.calendars, id: \.id) { calendar in
                Toggle(
                    isOn: Binding(
                        get: { calendarManager.getCalendarSelected(calendar) },
                        set: { isSelected in
                            Task {
                                await calendarManager.setCalendarSelected(
                                    calendar, isSelected: isSelected)
                            }
                        }
                    )
                ) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(calendar.color))
                            .frame(width: 10, height: 10)
                        Text(calendar.title)
                    }
                }
                .padding(.leading, 12)
                .accentColor(lighterColor(from: calendar.color))
                .disabled(!isEnabled)
            }
        }
    }
}

/// Account header row. On while any of the account's calendars is shown; flipping
/// it shows or hides all of them.
private struct AccountToggle: View {
    let group: CalendarAccountGroup
    @ObservedObject var calendarManager: CalendarManager

    private var selectedCount: Int {
        group.calendars.filter { calendarManager.getCalendarSelected($0) }.count
    }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { selectedCount > 0 },
                set: { isSelected in
                    Task {
                        await calendarManager.setCalendarsSelected(
                            group.calendars, isSelected: isSelected)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if group.isOther {
                        Text("Other")
                    } else {
                        Text(verbatim: group.title)
                    }
                }
                .fontWeight(.semibold)
                Text("\(selectedCount) of \(group.calendars.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}
