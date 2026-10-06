//
//  CalendarLayouts.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The calendar tab's three layouts, picked in Settings → Calendar:
//   • Up next — the next meeting front and center, the rest of the week beside it.
//   • Month and agenda — a mini month next to the selected day's agenda.
//   • Multi-day — a column per day, like a small week view.
//

import Defaults
import SwiftUI

// MARK: - Up next

struct UpNextCalendarLayout: View {
    @StateObject private var model = UpcomingEventsModel()

    private static let days = 7
    /// Today, tomorrow and the day after always get a heading, even when
    /// empty, so a quiet calendar keeps the same shape as a busy one.
    private static let alwaysShownDays = 3

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let next = UpcomingEvents.nextEvent(in: model.events, now: now)
            let later = UpcomingEvents.byDay(
                model.events.filter { $0.end > now && $0.occurrenceKey != next?.occurrenceKey },
                from: now,
                days: Self.days
            )
            .enumerated()
            .filter { $0.offset < Self.alwaysShownDays || !$0.element.events.isEmpty }
            .map(\.element)

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 14) {
                    UpNextCard(event: next, now: now)
                        .frame(width: geometry.size.width * 0.5)

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(later) { day in
                                CalendarDayHeader(day: day.day)
                                    .padding(.top, day.id == later.first?.id ? 0 : 4)
                                if day.events.isEmpty {
                                    // The card already shows this day's only event.
                                    let featuresThisDay = next.map { Calendar.current.isDate($0.start, inSameDayAs: day.day) } ?? false
                                    CalendarEmptyDayRow(text: featuresThisDay ? "Nothing else" : "No events")
                                } else {
                                    ForEach(day.events, id: \.occurrenceKey) { event in
                                        CalendarEventRow(event: event, now: now)
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .onAppear { model.load(from: .now, days: Self.days) }
    }
}

private struct UpNextCard: View {
    let event: EventModel?
    let now: Date

    var body: some View {
        Group {
            if let event {
                details(event)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("Nothing coming up")
                        .font(.callout)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Everything about the next item, written straight into the card: title
    /// and join button, then a line per detail (when, which day, time until
    /// or left, attendees, location), and the description in whatever room
    /// is left.
    private func details(_ event: EventModel) -> some View {
        let inProgress = event.start <= now
        let color = Color(nsColor: event.calendar.color)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    attendeeCount(event)
                }
                Spacer(minLength: 0)
                if let join = MeetingJoinButton(event: event, size: 24) {
                    join
                }
            }

            // The fullest version that fits the card wins: the description
            // shrinks first, then goes, then the location.
            ViewThatFits(in: .vertical) {
                detailLines(event, inProgress: inProgress, color: color, notesLines: 3, location: true)
                detailLines(event, inProgress: inProgress, color: color, notesLines: 1, location: true)
                detailLines(event, inProgress: inProgress, color: color, notesLines: 0, location: true)
                detailLines(event, inProgress: inProgress, color: color, notesLines: 1, location: false)
                detailLines(event, inProgress: inProgress, color: color, notesLines: 0, location: false)
            }
            // Otherwise the spacer below gets half the free height and a
            // smaller version wins with room to spare.
            .layoutPriority(1)

            Spacer(minLength: 0)

            if inProgress {
                CalendarProgressBar(
                    fraction: now.timeIntervalSince(event.start) / max(event.end.timeIntervalSince(event.start), 1),
                    color: color
                )
            }
        }
        .calendarEventInteractions(event)
    }

    @ViewBuilder
    private func detailLines(
        _ event: EventModel,
        inProgress: Bool,
        color: Color,
        notesLines: Int,
        location: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            UpNextDetail(systemImage: "clock") {
                Text((event.start..<event.end).formatted(date: .omitted, time: .shortened))
            }
            // Only for later days; today goes without saying.
            if !Calendar.current.isDateInToday(event.start) {
                UpNextDetail(systemImage: "calendar") {
                    Text(Self.dayText(for: event.start))
                }
            }
            UpNextDetail(systemImage: inProgress ? "hourglass" : "timer", tint: inProgress ? color : nil) {
                let countdown = calendarCountdown(to: inProgress ? event.end : event.start, from: now)
                Text(inProgress ? "\(countdown) left" : "in \(countdown)")
            }
            if location, let place = event.displayLocation {
                UpNextDetail(systemImage: "mappin.and.ellipse") {
                    Text(place)
                }
            }
            if notesLines > 0, let notes = event.displayNotes {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .frame(width: 14)
                    Text(notes)
                        .lineLimit(notesLines)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.gray)
            }
        }
    }

    /// Icon and count only, for meetings with other people.
    @ViewBuilder
    private func attendeeCount(_ event: EventModel) -> some View {
        if event.participants.count > 1 {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill")
                Text("\(event.participants.count)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.gray)
            .help("Attendees")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(event.participants.count) attendees")
        }
    }

    /// "Tomorrow" or "Tue, Oct 6" for items after today.
    private static func dayText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// One line of detail about the next item: an icon, then the fact.
private struct UpNextDetail<Content: View>: View {
    let systemImage: String
    var tint: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 14)
            content()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(tint ?? .gray)
    }
}

private struct CalendarProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Month and agenda

struct MonthAgendaCalendarLayout: View {
    @StateObject private var model = UpcomingEventsModel()
    @State private var displayedMonth = MiniMonth.startOfMonth(.now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @Default(.weekStartDay) private var weekStartDay

    private static let agendaDays = 7

    private var gridDays: [Date] {
        MiniMonth.days(for: displayedMonth, firstWeekday: weekStartDay.firstWeekday)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let grid = gridDays
            let eventDays = Set(
                UpcomingEvents.byDay(model.events, from: grid.first ?? now, days: grid.count)
                    .filter { !$0.events.isEmpty }
                    .map(\.day)
            )
            let agenda = UpcomingEvents.byDay(model.events, from: selectedDay, days: Self.agendaDays)
                .filter { !$0.events.isEmpty }

            HStack(alignment: .top, spacing: 12) {
                MiniMonthView(
                    month: $displayedMonth,
                    selectedDay: $selectedDay,
                    days: grid,
                    eventDays: eventDays,
                    firstWeekday: weekStartDay.firstWeekday
                )
                .frame(width: 196)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)

                if agenda.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.title2)
                            .foregroundStyle(.gray)
                        Text("Nothing scheduled")
                            .font(.callout)
                            .foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(agenda) { day in
                                CalendarDayHeader(day: day.day)
                                    .padding(.top, day.id == agenda.first?.id ? 0 : 4)
                                ForEach(day.events, id: \.occurrenceKey) { event in
                                    CalendarEventRow(event: event, now: now)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: displayedMonth) { reload() }
        .onChange(of: selectedDay) { reload() }
        .onChange(of: weekStartDay) { reload() }
    }

    /// One fetch covers both the visible month (for the event dots) and the
    /// week of agenda after the selected day, which can run past the grid.
    private func reload() {
        let calendar = Calendar.current
        let grid = gridDays
        let agendaEnd = calendar.date(byAdding: .day, value: Self.agendaDays, to: selectedDay) ?? selectedDay
        let start = min(grid.first ?? selectedDay, selectedDay)
        let end = max(grid.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? agendaEnd, agendaEnd)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? Self.agendaDays
        model.load(from: start, days: max(days, 1))
    }
}

enum MiniMonth {
    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Every day shown in a month grid: whole weeks from the one containing
    /// the 1st through the one containing the last day, starting on
    /// `firstWeekday` (1 = Sunday … 7 = Saturday).
    static func days(for month: Date, firstWeekday: Int, calendar: Calendar = .current) -> [Date] {
        let first = startOfMonth(month, calendar: calendar)
        guard let dayCount = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7
        let cells = Int((Double(leading + dayCount) / 7).rounded(.up)) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: first) }
    }
}

private struct MiniMonthView: View {
    @Binding var month: Date
    @Binding var selectedDay: Date
    let days: [Date]
    let eventDays: Set<Date>
    let firstWeekday: Int

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let start = (firstWeekday - 1) % 7
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                monthButton(systemImage: "chevron.left", offset: -1, label: "Previous month")
                monthButton(systemImage: "chevron.right", offset: 1, label: "Next month")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.gray)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private func monthButton(systemImage: String, offset: Int, label: LocalizedStringKey) -> some View {
        Button {
            if let target = Calendar.current.date(byAdding: .month, value: offset, to: month) {
                month = MiniMonth.startOfMonth(target)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.gray)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)

        return Text("\(calendar.component(.day, from: day))")
            .font(.subheadline.weight(isToday ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(isToday ? Color.white : inMonth ? Color(white: 0.85) : Color.gray.opacity(0.5))
            .frame(width: 22, height: 15)
            .background {
                if isToday {
                    Capsule().fill(Color.effectiveAccent)
                } else if isSelected {
                    Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if eventDays.contains(day) && !isToday {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 3, height: 3)
                        .offset(y: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedDay = day
                if !inMonth { month = MiniMonth.startOfMonth(day) }
            }
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Multi-day

struct MultiDayCalendarLayout: View {
    @StateObject private var model = UpcomingEventsModel()

    private static let days = 4

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let columns = UpcomingEvents.byDay(model.events, from: now, days: Self.days)

            HStack(alignment: .top, spacing: 8) {
                ForEach(columns) { column in
                    VStack(alignment: .leading, spacing: 5) {
                        CalendarDayHeader(day: column.day, isEmphasized: Calendar.current.isDateInToday(column.day))
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 4) {
                                if column.events.isEmpty {
                                    CalendarEmptyDayRow(text: "No events")
                                }
                                ForEach(column.events, id: \.occurrenceKey) { event in
                                    CalendarEventChip(event: event, now: now)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear { model.load(from: .now, days: Self.days) }
    }
}

private struct CalendarEventChip: View {
    let event: EventModel
    let now: Date
    @Default(.showFullEventTitles) private var showFullEventTitles

    private var time: Text {
        event.isAllDay
            ? Text(Image(systemName: "sun.max.fill"))
            : Text(event.start.formatted(date: .omitted, time: .shortened))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(time.foregroundStyle(.white.opacity(0.65))) \(Text(event.title).foregroundStyle(.white))")
                .font(.caption)
                .lineLimit(showFullEventTitles ? 3 : 2)
                .truncationMode(.tail)
                .strikethrough(event.attendance == .declined)
            Spacer(minLength: 0)
            if event.end > now, let join = MeetingJoinButton(event: event, size: 16) {
                join
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: event.calendar.color).opacity(0.3))
        )
        .opacity(event.end <= now ? 0.5 : 1)
        .calendarEventInteractions(event)
    }
}

// MARK: - Helpers

extension EventModel {
    /// The description as readable text: HTML stripped (Google sends HTML),
    /// links and the join/dial-in boilerplate meeting invites append removed
    /// (the join button covers those), and whitespace collapsed. Nil if
    /// nothing is left.
    var displayNotes: String? {
        guard let notes else { return nil }
        return Self.readableNotes(notes)
    }

    static func readableNotes(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        let boilerplate = [
            "join with google meet", "join by phone", "more phone numbers", "learn more about meet",
            "meeting link", "meeting id", "passcode", "pin:", "join zoom meeting", "dial by your location",
            "microsoft teams meeting", "join the meeting now", "join on your computer", "click here to join",
            "-::~:~::", "please do not edit this section",
        ]
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                return !line.isEmpty
                    && !boilerplate.contains(where: lower.contains)
                    && line.rangeOfCharacter(from: .letters) != nil
            }
        text = lines.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A place worth showing next to a pin: not empty, and not just the
    /// meeting URL (which gets the join button instead).
    var displayLocation: String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty,
              !location.lowercased().hasPrefix("http")
        else { return nil }
        return location
    }
}
