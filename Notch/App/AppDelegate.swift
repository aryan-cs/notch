//
//  AppDelegate.swift
//  Notch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import SwiftUI

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = CameraModel()
    @ObservedObject var coordinator = NotchCoordinator.shared
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
    var viewModels: [String: NotchViewModel] { windowManager.viewModels }
    var vm: NotchViewModel { windowManager.primaryViewModel }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// With a notch on every display, the one under the pointer; otherwise
    /// the primary notch.
    private func viewModelUnderMouse() -> NotchViewModel {
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
        NotchHelperClient.shared.stopMonitoringAccessibilityAuthorization()

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
        audioPlayer.play(fileName: "welcome", fileExtension: "m4a")
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
