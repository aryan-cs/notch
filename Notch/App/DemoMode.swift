//
//  DemoMode.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Demo mode fills the real views with made-up content for screenshots, so
//  nobody's own music, calendar or files appear in them. It exists only in
//  Debug builds; in Release both flags are constant `false`.
//

import AppKit
import Defaults
import SwiftUI

enum DemoMode {
#if DEBUG
    nonisolated(unsafe) static var isActive = false
    /// Keeps the notch open while a screenshot is taken.
    nonisolated(unsafe) static var holdOpen = false
#else
    static let isActive = false
    static let holdOpen = false
#endif
}

#if DEBUG
// MARK: - Demo mode (development builds only)

extension Notification.Name {
    /// Asks the Settings window to show a page; the object is the page's raw value.
    static let notchDemoSettingsPage = Notification.Name("notchDemoSettingsPage")
}

/// Drives the running app for README screenshots. Send a command from
/// Terminal, e.g.:
///   swift -e 'import Foundation; DistributedNotificationCenter.default()
///     .postNotificationName(.init("notch.demo"), object: "open calendar",
///     userInfo: nil, deliverImmediately: true)'
/// Commands: start, open <home|calendar|shelf|clipboard|devices>, close,
/// peek, volume, notification, snap, faceid, clear, settings <page>.
/// Demo content is never saved; restart Notch afterwards to get your own back.
extension AppDelegate {
    func observeDemoCommands() {
        demoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("notch.demo"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { self?.runDemoCommand(command) }
        }
    }

    /// The notch on the main display (with "Show on all displays", the
    /// primary view model has no window of its own).
    private var demoViewModel: NotchViewModel {
        if let uuid = NSScreen.main?.displayUUID, let model = viewModels[uuid] { return model }
        return vm
    }

    private func runDemoCommand(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        Log.app.notice("demo: \(command, privacy: .public)")
        let model = demoViewModel

        switch verb {
        case "start":
            DemoMode.isActive = true
            NotchDemoContent.load()
            // Let screenshots see the notch even with "Hide from screen recording" on.
            for case let window as NotchWindow in NSApp.windows { window.updateSharingType() }
            for window in NSApp.windows where window is NotchWindow {
                Log.app.notice("demo window \(window.windowNumber) frame \(NSStringFromRect(window.frame), privacy: .public)")
            }
        case "open":
            clearDemoOverlays(model)
            DemoMode.holdOpen = true
            model.open()
            let tabs: [String: NotchTab] = ["home": .home, "calendar": .calendar, "shelf": .shelf,
                                              "clipboard": .clipboard, "devices": .devices]
            coordinator.currentView = tabs[argument] ?? .home
        case "close":
            clearDemoOverlays(model)
            DemoMode.holdOpen = false
            model.close()
        case "peek":
            runDemoCommand("close")
            coordinator.toggleSneakPeek(status: true, type: .music, duration: 3600, targetScreenUUID: model.screenUUID)
        case "volume":
            runDemoCommand("close")
            coordinator.toggleSneakPeek(status: true, type: .volume, duration: 3600, value: 0.65,
                                        icon: "speaker.wave.2.fill", targetScreenUUID: model.screenUUID)
        case "notification":
            SystemNotificationManager.shared.demoShow(NotchDemoContent.notification)
        case "snap":
            clearDemoOverlays(model)
            DemoMode.holdOpen = true
            if let screen = NSScreen.main {
                WindowSnapController.shared.demoShowPicker(on: screen, viewModel: model, highlighting: .leftHalf)
            }
        case "faceid":
            FaceUnlockManager.shared.demoFaceID()
        case "clear":
            clearDemoOverlays(model)
        case "settings":
            SettingsWindowController.shared.showWindow()
            NotificationCenter.default.post(name: .notchDemoSettingsPage, object: argument)
        default:
            Log.app.error("demo: unknown command \(command, privacy: .public)")
        }
    }

    private func clearDemoOverlays(_ model: NotchViewModel) {
        coordinator.toggleSneakPeek(status: false, type: .music, targetScreenUUID: model.screenUUID)
        SystemNotificationManager.shared.demoDismiss()
        WindowSnapController.shared.demoHidePicker()
    }
}

/// The made-up content shown in demo mode.
@MainActor
enum NotchDemoContent {
    /// Images and files prepared for the demo, in the app's own Caches folder.
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchDemo", isDirectory: true)
    }

    static func load() {
        let cover = NSImage(contentsOf: folder.appendingPathComponent("cover.jpg")) ?? NSImage()
        // The neon red of the cover's sign, so the accent matches the album.
        let neonRed = NSColor(srgbRed: 235 / 255, green: 38 / 255, blue: 19 / 255, alpha: 1)
        MusicManager.shared.demoPlay(title: "She's a Lover", artist: "Red Hot Chili Peppers",
                                     album: "Unlimited Love", art: cover, accent: neonRed,
                                     duration: 221, elapsed: 83)
        UpcomingEventsModel.demoEvents = events()
        ClipboardHistoryManager.shared.demoShow(clipboard())
        ShelfStateViewModel.shared.demoShow(shelf())
        NotchDevicesModel.demoDevices = devices()
    }

    // MARK: Calendar

    private static func events() -> [EventModel] {
        let work = CalendarModel(id: "demo-work", account: "Work", accountID: "demo-work", isGoogleAccount: false,
                                 title: "Work", color: .systemBlue, isSubscribed: false, isReminder: false)
        let personal = CalendarModel(id: "demo-personal", account: "Personal", accountID: "demo-personal",
                                     isGoogleAccount: false, title: "Personal", color: .systemOrange,
                                     isSubscribed: false, isReminder: false)
        let reminders = CalendarModel(id: "demo-reminders", account: "Personal", accountID: "demo-personal",
                                      isGoogleAccount: false, title: "Reminders", color: .systemPurple,
                                      isSubscribed: false, isReminder: true)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        func people(_ names: [String]) -> [Participant] {
            names.enumerated().map { index, name in
                Participant(name: name, status: .accepted, isOrganizer: index == 0, isCurrentUser: false)
            }
        }
        func meeting(_ url: String, _ provider: MeetingProvider) -> MeetingLink? {
            URL(string: url).map { MeetingLink(url: $0, provider: provider) }
        }
        func event(_ id: String, _ title: String, _ start: Date, minutes: Int, calendar model: CalendarModel = work,
                   location: String? = nil, notes: String? = nil, people names: [String] = [],
                   link: MeetingLink? = nil, type: EventType = .event(.accepted)) -> EventModel {
            EventModel(id: id, externalID: nil, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                       title: title, location: location, notes: notes, url: nil, isAllDay: false, type: type,
                       calendar: model, participants: people(names), timeZone: nil, hasRecurrenceRules: false,
                       priority: nil, meetingLink: link)
        }
        // The next meeting starts in about 20 minutes, whatever time it is.
        let soon = calendar.date(bySetting: .second, value: 0, of: now.addingTimeInterval(20 * 60)) ?? now
        return [
            event("demo-1", "Design Review", soon, minutes: 45,
                  notes: "Walk through the new Face Unlock settings and the README screenshots.",
                  people: ["Maya Chen", "Jordan Lee", "Sam Patel", "Alex Rivera"],
                  link: meeting("https://meet.google.com/abc-defg-hij", .googleMeet)),
            event("demo-2", "1:1 with Maya", soon.addingTimeInterval(90 * 60), minutes: 30,
                  people: ["Maya Chen", "You"], link: meeting("https://zoom.us/j/1234567890", .zoom)),
            event("demo-3", "Team Standup", day(1, 9, 30), minutes: 15,
                  people: ["Jordan Lee", "Maya Chen", "Sam Patel"],
                  link: meeting("https://meet.google.com/xyz-abcd-efg", .googleMeet)),
            event("demo-4", "Product Sync", day(1, 11), minutes: 60,
                  people: ["Alex Rivera", "Jordan Lee"],
                  link: meeting("https://teams.microsoft.com/l/meetup-join/demo", .teams)),
            event("demo-5", "Lunch with Alex", day(1, 13), minutes: 60, calendar: personal, location: "Tartine Manufactory"),
            event("demo-6", "Launch Retro", day(1, 16), minutes: 45, people: ["Maya Chen", "Sam Patel", "Jordan Lee"],
                  link: meeting("https://zoom.us/j/9876543210", .zoom)),
            event("demo-7", "Send launch notes", day(1, 17), minutes: 0, calendar: reminders,
                  type: .reminder(completed: false)),
            event("demo-8", "Climbing", day(2, 18, 30), minutes: 90, calendar: personal, location: "Mission Cliffs"),
            event("demo-9", "Roadmap Planning", day(3, 10), minutes: 90, people: ["Alex Rivera", "Maya Chen"],
                  link: meeting("https://zoom.us/j/5550101234", .zoom)),
        ]
    }

    // MARK: Clipboard

    private static func clipboard() -> [ClipboardEntry] {
        func text(_ value: String, minutesAgo: Double, app: String, pinned: Bool = false) -> ClipboardEntry {
            ClipboardEntry(content: .text(value, rtf: nil), fingerprint: ClipboardEntry.fingerprint(text: value),
                           date: Date().addingTimeInterval(-minutesAgo * 60), sourceBundleID: app, isPinned: pinned)
        }
        return [
            text("Let's ship Notch 1.0.1 today 🚀", minutesAgo: 1, app: "com.apple.MobileSMS"),
            text("https://github.com/aryan-cs/notch", minutesAgo: 4, app: "com.apple.Safari"),
            text("#FF5A5F", minutesAgo: 7, app: "com.figma.Desktop"),
            text("git push origin main", minutesAgo: 12, app: "com.apple.Terminal"),
            text("#7C5CFF", minutesAgo: 18, app: "com.figma.Desktop"),
            text("Launch checklist: README screenshots, release notes, tag v1.0.1", minutesAgo: 26, app: "com.apple.Notes"),
            text("Flight UA 1549 · Seat 12A", minutesAgo: 240, app: "com.apple.mail", pinned: true),
        ]
    }

    // MARK: Shelf

    private static func shelf() -> [ShelfItem] {
        var items: [ShelfItem] = []
        for name in ["Launch Plan.pdf", "Moodboard.png"] {
            let url = folder.appendingPathComponent(name)
            if let bookmark = try? Bookmark(url: url) {
                items.append(ShelfItem(kind: .file(bookmark: bookmark.data)))
            }
        }
        if let link = URL(string: "https://github.com/aryan-cs/notch/releases") {
            items.append(ShelfItem(kind: .link(url: link)))
        }
        return items
    }

    // MARK: Devices

    private static func devices() -> [NotchDevice] {
        [
            NotchDevice(id: "demo-airpods", name: "AirPods Pro", kind: .earbuds("airpodspro"),
                        bluetoothAddress: "00-00-00-00-00-01", isConnected: true,
                        battery: DeviceBattery(left: 85, right: 80, caseLevel: 62), audioOutputID: nil),
            NotchDevice(id: "demo-iphone", name: "iPhone", kind: .phone, bluetoothAddress: nil, isConnected: true,
                        battery: DeviceBattery(single: 72, isCharging: true), audioOutputID: nil),
            NotchDevice(id: "demo-watch", name: "Apple Watch", kind: .watch, bluetoothAddress: nil, isConnected: true,
                        battery: DeviceBattery(single: 58), audioOutputID: nil),
            NotchDevice(id: "demo-keyboard", name: "Magic Keyboard", kind: .keyboard,
                        bluetoothAddress: "00-00-00-00-00-02", isConnected: true,
                        battery: DeviceBattery(single: 91), audioOutputID: nil),
            NotchDevice(id: "demo-mouse", name: "Magic Mouse", kind: .mouse,
                        bluetoothAddress: "00-00-00-00-00-03", isConnected: true,
                        battery: DeviceBattery(single: 34), audioOutputID: nil),
        ]
    }

    // MARK: Notification

    static let notification = SystemNotification(
        id: "demo-notification", appName: "Messages", bundleID: "com.apple.MobileSMS",
        title: "Maya Chen", subtitle: nil,
        body: "Just tried Face Unlock on the new build. It's so fast 😮",
        receivedAt: Date())
}
#endif
