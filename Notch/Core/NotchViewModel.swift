//
//  NotchViewModel.swift
//  Notch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

final class NotchViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = NotchCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animation: Animation?
    let dropInteraction = DropInteractionState()

    @Published private(set) var notchState: NotchState = .closed

    var cancellables: Set<AnyCancellable> = []

    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    /// Keeps the open notch alive while a popover is showing.
    @Published var isPopoverActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()

    let camera: CameraModel

    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil, camera: CameraModel) {
        animation = StandardAnimations.bouncy
        self.camera = camera
        self.screenUUID = screenUUID

        super.init()

        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        setupDetectorObserver()
    }

    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    /// Whether the current screen has a notch (safe area top inset > 0)
    var hasNotch: Bool {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        return (currentScreen?.safeAreaInsets.top ?? 0) > 0
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        switch camera.state {
        case .running, .interrupted:
            camera.stopSession()
        case .stopped, .unavailable, .failed:
            if camera.cameraAvailable {
                camera.startSession()
            }

        case .permissionDenied:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Camera Access Required", comment: "Camera permission alert title")
                alert.informativeText = NSLocalizedString("Please allow camera access in System Settings.", comment: "Camera permission alert message")
                alert.addButton(withTitle: NSLocalizedString("Open Settings", comment: "Button title that opens app or system settings"))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button title"))

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .permissionRequired:
            camera.requestAccess()

        case .requestingPermission, .starting:
            break
        }
    }

    @discardableResult
    func open() -> Bool {
        guard !coordinator.firstLaunch, notchState != .open else { return false }

        self.notchSize = openNotchSize
        self.notchState = .open

        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()

        return true
    }

    func close() {
        if DemoMode.holdOpen { return }  // a demo screenshot is being taken
        // Do not close while a share picker or sharing service is active
        if SharingStateManager.shared.preventNotchClose {
            return
        }
        // The camera is on-demand: the notch closing always ends capture.
        // Intent clears too, so no recovery path can reopen it while closed.
        camera.stopSession()
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.isPopoverActive = false
        if self.coordinator.shouldShowSneakPeek(on: self.screenUUID) {
            self.coordinator.toggleSneakPeek(status: false, type: .music, targetScreenUUID: self.screenUUID)
        }
        self.edgeAutoOpenActive = false

        // "Remember last tab" wins: it's an explicit opt-in, whereas opening
        // the shelf when it has items is on by default and used to silently
        // override it. Otherwise fall back to the shelf (if it has items and
        // openShelfByDefault is on) or home.
        if coordinator.openLastTabByDefault {
            // Leave currentView as the user left it.
        } else if Defaults[.shelfEnabled] && !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] {
            coordinator.currentView = .shelf
        } else {
            coordinator.currentView = .home
        }
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(StandardAnimations.bouncy) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}
