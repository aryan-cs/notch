//
//  CalendarTabView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The calendar tab: shows whichever layout is picked in Settings →
//  Calendar, plus the pieces the layouts share. Actions are icons wherever
//  an icon is clear on its own (a video button to join a call, a sun for
//  all-day, a pin for location).
//

import AppKit
import Defaults
import EventKit
import SwiftUI

struct CalendarTabView: View {
    @Default(.calendarLayout) private var layout

    var body: some View {
        Group {
            if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                CalendarAccessNeededView()
            } else {
                switch layout {
                case .upNext:
                    UpNextCalendarLayout()
                case .monthAgenda:
                    MonthAgendaCalendarLayout()
                case .multiDay:
                    MultiDayCalendarLayout()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CalendarAccessNeededView: View {
    var body: some View {
        Button {
            SettingsWindowController.shared.showWindow()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.gray)
                Text("Calendar access is off")
                    .font(.callout)
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings")
    }
}

// MARK: - Shared pieces

/// Joins a call. Styled after FaceTime: a white camera on green. Uses the
/// account-aware link, so Google Meet opens in the calendar's account.
struct MeetingJoinButton: View {
    let link: MeetingLink
    let url: URL
    var size: CGFloat = 22
    @Environment(\.openURL) private var openURL

    init?(event: EventModel, size: CGFloat = 22) {
        guard let link = event.meetingLink else { return nil }
        self.link = link
        self.url = event.meetingJoinURL ?? link.url
        self.size = size
    }

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Image(systemName: "video.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.35)))
        }
        .buttonStyle(.plain)
        .help("Join \(link.provider.displayName)")
        .accessibilityLabel("Join \(link.provider.displayName)")
    }
}

extension View {
    /// Tap and right-click behavior shared by every event in the calendar
    /// tab. A tap only ever joins the meeting (when "Join meeting when
    /// tapping an event" is on); it never opens Calendar, which pulled focus
    /// away mid-glance. Calendar stays one right-click away.
    func calendarEventInteractions(_ event: EventModel) -> some View {
        modifier(CalendarEventInteractions(event: event))
    }
}

private struct CalendarEventInteractions: ViewModifier {
    let event: EventModel
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                if let joinURL = event.meetingJoinURL, Defaults[.joinMeetingOnEventTap] {
                    openURL(joinURL)
                }
            }
            .contextMenu {
                if let url = event.calendarAppURL() {
                    Button("Open in Calendar") { openURL(url) }
                }
                if let link = event.meetingLink {
                    Button("Copy Meeting Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                    }
                }
            }
    }
}

/// One line in an agenda list: calendar color, title, then a join button
/// and the time (a sun for all-day events).
struct CalendarEventRow: View {
    let event: EventModel
    let now: Date
    @Default(.showFullEventTitles) private var showFullEventTitles

    var body: some View {
        HStack(spacing: 7) {
            CalendarColorMarker(event: event)
            Text(event.title)
                .font(.callout)
                .foregroundStyle(event.attendance == .declined ? .gray : .white)
                .strikethrough(event.attendance == .declined)
                .lineLimit(showFullEventTitles ? 2 : 1)
                .truncationMode(.tail)
            // Right after the title, sized to the text.
            if event.end > now, let join = MeetingJoinButton(event: event, size: 16) {
                join
            }
            Spacer(minLength: 4)
            CalendarEventTime(event: event)
        }
        .opacity(event.end <= now ? 0.5 : 1)
        .calendarEventInteractions(event)
    }
}

/// The calendar's color as a dot; reminders get an open circle instead.
struct CalendarColorMarker: View {
    let event: EventModel

    var body: some View {
        if event.type.isReminder {
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color(nsColor: event.calendar.color))
                .frame(width: 8)
        } else {
            Circle()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 7, height: 7)
        }
    }
}

struct CalendarEventTime: View {
    let event: EventModel

    /// The widest time this locale shows ("10:58 PM", or "22:58"). Every time
    /// sits right-aligned in a slot this wide, so the column lines up.
    private static let widestTime: String = {
        let date = Calendar.current.date(from: DateComponents(hour: 22, minute: 58)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }()

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(Self.widestTime).hidden()  // reserves the slot's width
            if event.isAllDay {
                Image(systemName: "sun.max.fill")
                    .help("All day")
                    .accessibilityLabel("All day")
            } else {
                Text(event.start.formatted(date: .omitted, time: .shortened))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.gray)
        .lineLimit(1)
    }
}

/// Placeholder under a day heading with no events, muted so it reads as
/// part of the structure rather than content.
struct CalendarEmptyDayRow: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.gray.opacity(0.6))
            .lineLimit(1)
    }
}

struct CalendarDayHeader: View {
    let day: Date
    var isEmphasized = false

    var body: some View {
        Text(Self.label(for: day))
            .font(.caption.weight(.semibold))
            .foregroundStyle(isEmphasized ? .white : .gray)
            .lineLimit(1)
    }

    static func label(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// "20m", "1h 5m": time until a moment, rounded up to the minute.
func calendarCountdown(to date: Date, from now: Date) -> String {
    let seconds = max(0, date.timeIntervalSince(now))
    let minutes = (seconds / 60).rounded(.up)
    return Duration.seconds(minutes * 60).formatted(
        .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
    )
}
