//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon

    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView()
            Button("Restart Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

/// Development-only demo mode for README screenshots: the app's real views
/// filled with made-up content, so no one's own data appears. Compiled out of
/// release builds, where both flags are constant `false`.
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

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager` (see managers/NotchWindowManager.swift).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = CameraModel()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var closeNotchTask: Task<Void, Never>?
    private lazy var windowManager = NotchWindowManager(camera: camera)
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
#if DEBUG
    var demoObserver: Any?
#endif
    private var observers: [Any] = []
    private var activeDisplayObserver: NSObjectProtocol?
    private var displayModeTask: Task<Void, Never>?
    private var observedDisplayMode: DisplayMode?

    /// Kept for existing internal readers; the state itself moved to the manager.
    var windows: [String: NSWindow] { windowManager.windows }
    var viewModels: [String: BoringViewModel] { windowManager.viewModels }
    var vm: BoringViewModel { windowManager.primaryViewModel }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// With a notch on every display, the one under the pointer; otherwise
    /// the primary notch.
    private func viewModelUnderMouse() -> BoringViewModel {
        guard Defaults[.displayMode] == .allDisplays else { return vm }
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
            if let uuid = screen.displayUUID, let screenViewModel = viewModels[uuid] {
                return screenViewModel
            }
        }
        return vm
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush debounced shelf persistence to avoid losing recent changes
        ShelfStateViewModel.shared.flushSync()
        ClipboardHistoryManager.shared.flushSync()

        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MainActor.assumeIsolated {
            MusicManager.shared.destroy()
            windowManager.cleanup()
        }
        BetterDisplayManager.shared.stopObserving()
        LunarManager.shared.stopListening()
        LunarManager.shared.configureLunarOSD(hide: false)
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        displayModeTask?.cancel()
        MainActor.assumeIsolated { setActiveDisplayObserver(enabled: false, reposition: false) }
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        Log.faceUnlock.notice("screen locked")
        windowManager.screenLocked()
        FaceUnlockManager.shared.startLive()
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        Log.faceUnlock.notice("screen unlocked")
        windowManager.screenUnlocked()
        FaceUnlockManager.shared.stopLive()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.shared.setCamera(camera)
        migrateDisplayModeIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition(changeAlpha: true)
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition()
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.setupDragDetectors()
            }
        })

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }
#if DEBUG
        observeDemoCommands()
#endif

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
                KeyboardShortcuts.onKeyUp(for: .toggleSneakPeek) {
                    self.coordinator.toggleSneakPeek(
                        status: !self.coordinator.isAnySneakPeekShowing,
                        type: .music
                    )
                }
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.isAnySneakPeekShowing,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let viewModel = self.viewModelUnderMouse()

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    var didOpen = false
                    await MainActor.run {
                        didOpen = viewModel.open()
                    }
                    guard didOpen else { return }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // Opens straight to the clipboard tab; pressing it again while that
        // tab is showing closes the notch. No auto-close timer, unlike
        // toggleNotchOpen — the user still has to move over and pick a card.
        KeyboardShortcuts.onKeyDown(for: .openClipboardHistory) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, Defaults[.clipboardHistory] else { return }
                let viewModel = self.viewModelUnderMouse()

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                if viewModel.notchState == .open && self.coordinator.currentView == .clipboard {
                    viewModel.close()
                    return
                }
                if viewModel.notchState == .closed {
                    guard viewModel.open() else { return }
                }
                withAnimation(.smooth) {
                    self.coordinator.currentView = .clipboard
                }
            }
        }

        // Sync notch height with real value on app launch if mode is matchRealNotchSize
        syncNotchHeightIfNeeded()

        windowManager.prepareInitialWindows()

        displayModeTask = Task { @MainActor [weak self] in
            for await mode in Defaults.updates(.displayMode, initial: true) {
                guard let self else { return }

                let previousMode = self.observedDisplayMode
                self.observedDisplayMode = mode

                if let previousMode, (previousMode == .allDisplays) != (mode == .allDisplays) {
                    self.windowManager.cleanupWindows(shouldInvert: true)
                }

                self.setActiveDisplayObserver(enabled: mode == .activeDisplay, reposition: false)
                self.windowManager.adjustWindowPosition(changeAlpha: true)
                self.windowManager.setupDragDetectors()
            }
        }

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        }

        // make sure OSD subsystems are in the right state now that initial
        // notch windows have been created/cleaned up
        coordinator.applyOSDSources()

        // Alert mode: idle until it's enabled and switched on. It stays off
        // the camera while the mirror has it.
        PresenceGuard.shared.start { [camera] in
            camera.isIntendedRunning || camera.isSessionRunning
        }
    }

    private func migrateDisplayModeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "displayMode") == nil else { return }

        let mode: DisplayMode
        if Defaults[.showOnAllDisplays] {
            mode = .allDisplays
        } else if Defaults[.followActiveDisplay] {
            mode = .activeDisplay
        } else if Defaults[.automaticallySwitchDisplay] {
            mode = .fallbackIfPreferredUnavailable
        } else {
            mode = .preferredDisplay
        }

        Defaults[.displayMode] = mode
    }

    private static let activeDisplayDidChangeNotification =
        Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")

    @MainActor
    private func setActiveDisplayObserver(enabled: Bool, reposition: Bool = true) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if enabled {
            guard activeDisplayObserver == nil else { return }

            activeDisplayObserver = workspaceCenter.addObserver(
                forName: Self.activeDisplayDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.windowManager.adjustWindowPosition(changeAlpha: true)
                    self.windowManager.setupDragDetectors()
                }
            }
        } else if let observer = activeDisplayObserver {
            workspaceCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }

        guard reposition else { return }

        windowManager.adjustWindowPosition(changeAlpha: true)
        windowManager.setupDragDetectors()
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    @objc func screenConfigurationDidChange() {
        windowManager.screenConfigurationDidChange()
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.level = .floating
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
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
    private var demoViewModel: BoringViewModel {
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
            for case let window as BoringNotchSkyLightWindow in NSApp.windows { window.updateSharingType() }
            for window in NSApp.windows where window is BoringNotchSkyLightWindow {
                Log.app.notice("demo window \(window.windowNumber) frame \(NSStringFromRect(window.frame), privacy: .public)")
            }
        case "open":
            clearDemoOverlays(model)
            DemoMode.holdOpen = true
            model.open()
            let tabs: [String: NotchViews] = ["home": .home, "calendar": .calendar, "shelf": .shelf,
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

    private func clearDemoOverlays(_ model: BoringViewModel) {
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
