//
//  WindowSnapController.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Window snapping: drag any app's window up into the notch and it opens
//  into a picker of layouts; let go over one and the window fills that part
//  of the screen.
//
//  A mouse drag only counts once it's seen to be carrying a window — the
//  window under the press moves while keeping its size. The window server
//  reports that without any permission, so the check runs here; moving the
//  window afterwards needs Accessibility, which only the helper has.
//

import AppKit
import Defaults
import Observation

@MainActor
@Observable
final class WindowSnapController {
    static let shared = WindowSnapController()

    /// The notch currently showing the picker.
    private(set) var pickerOwner: ObjectIdentifier?
    /// The tile under the cursor, highlighted in the picker.
    private(set) var hoveredLayout: SnapLayout?

    func isShowingPicker(for viewModel: NotchViewModel) -> Bool {
        pickerOwner == ObjectIdentifier(viewModel)
    }

    /// The notch shown on a screen, if any; supplied by NotchWindowManager.
    @ObservationIgnored var viewModelForScreen: ((NSScreen) -> NotchViewModel?)?

    /// The picker's tile grid, registered by the view. Its frame on screen is
    /// what the cursor is hit-tested against.
    @ObservationIgnored weak var gridView: NSView?

    private enum DragState {
        case idle
        /// Button down, not moved far enough to look at windows yet.
        case pressed(at: CGPoint)
        /// Waiting to see whether the window under the press moves.
        case watching(TrackedWindow, pressedAt: CGPoint, since: Date, lastCheck: Date)
        /// The drag is carrying this window.
        case carrying(TrackedWindow)
        /// Not a window drag; nothing more to do until the button comes up.
        case ignored
    }

    @ObservationIgnored private var state: DragState = .idle
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private weak var pickerViewModel: NotchViewModel?
    @ObservationIgnored private var pickerScreen: NSScreen?
    @ObservationIgnored private var isAccessibilityTrusted = false
    @ObservationIgnored private var settingTask: Task<Void, Never>?

    /// Movement before the window under the press is looked up — keeps plain
    /// clicks free of any window-server queries.
    private let dragThreshold: CGFloat = 3
    /// How often a candidate window's bounds are re-read while waiting.
    private let watchInterval: TimeInterval = 0.04
    /// Give up on a window that hasn't moved by now: the drag is selecting
    /// text, scrolling, drawing…
    private let watchDistance: CGFloat = 120
    private let watchDuration: TimeInterval = 1.5

    private init() {
        settingTask = Task { @MainActor [weak self] in
            for await enabled in Defaults.updates(.windowSnapping, initial: true) {
                self?.setMonitoring(enabled)
            }
        }
    }

    // MARK: - Monitoring

    private func setMonitoring(_ enabled: Bool) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        hidePicker()
        state = .idle
        guard enabled else { return }

        // Mouse events reach global monitors without Accessibility access.
        let added: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDown() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDragged() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseUp() }
            },
            // Events that land on our own windows skip global monitors. A
            // window drag shouldn't route any here, but if the release does,
            // the picker must still hear it.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let isUp = event.type == .leftMouseUp
                MainActor.assumeIsolated {
                    if isUp { self?.mouseUp() } else { self?.mouseDragged() }
                }
                return event
            }
        ]
        monitors = added.compactMap { $0 }

        Task { await refreshAccessibilityTrust() }
    }

    private func refreshAccessibilityTrust() async {
        isAccessibilityTrusted = await NotchHelperClient.shared.isAccessibilityAuthorized()
    }

    // MARK: - Drag tracking

    private func mouseDown() {
        // A picker left over from a drag whose release we missed.
        if pickerOwner != nil { hidePicker() }
        state = .pressed(at: NSEvent.mouseLocation)
    }

    private func mouseDragged() {
        let location = NSEvent.mouseLocation

        switch state {
        case .idle, .ignored:
            return

        case .pressed(let start):
            guard hypot(location.x - start.x, location.y - start.y) >= dragThreshold else { return }
            guard let primaryHeight = NSScreen.screens.first?.frame.maxY,
                  let window = TrackedWindow.under(ScreenCoordinates.flip(start, primaryScreenHeight: primaryHeight))
            else {
                state = .ignored
                return
            }
            state = .watching(window, pressedAt: start, since: Date(), lastCheck: .distantPast)

        case .watching(let window, let start, let since, let lastCheck):
            let now = Date()
            guard now.timeIntervalSince(lastCheck) >= watchInterval else { return }
            guard let bounds = window.currentBounds() else {
                state = .ignored
                return
            }
            switch WindowMotion(from: window.bounds, to: bounds) {
            case .moved:
                state = .carrying(window)
                // Fresh for this drag: it decides whether the picker shows,
                // and lands long before the cursor reaches the notch.
                Task { await refreshAccessibilityTrust() }
                update(location)
            case .resized:
                state = .ignored
            case .unchanged:
                let travelled = hypot(location.x - start.x, location.y - start.y)
                if travelled > watchDistance || now.timeIntervalSince(since) > watchDuration {
                    state = .ignored
                } else {
                    state = .watching(window, pressedAt: start, since: since, lastCheck: now)
                }
            }

        case .carrying:
            update(location)
        }
    }

    private func mouseUp() {
        defer { state = .idle }
        guard case .carrying(let window) = state, let screen = pickerScreen else {
            hidePicker()
            return
        }
        // Hit-tested afresh: the release can land a few points from the last
        // drag event.
        let location = NSEvent.mouseLocation
        if SnapZones.retain(screenFrame: screen.frame, openNotchSize: openNotchSize).contains(location),
           let layout = layout(at: location, on: screen) {
            snap(window, to: layout, on: screen)
        }
        hidePicker()
    }

    /// Opens, updates or dismisses the picker for a cursor carrying a window.
    private func update(_ location: CGPoint) {
        if let screen = pickerScreen {
            guard pickerViewModel != nil,
                  SnapZones.retain(screenFrame: screen.frame, openNotchSize: openNotchSize).contains(location)
            else {
                hidePicker()
                return
            }
            setHoveredLayout(layout(at: location, on: screen))
            return
        }

        guard isAccessibilityTrusted else { return }
        let screens = NSScreen.screens
        guard let index = SnapZones.screenIndex(containing: location, in: screens.map(\.frame)) else { return }
        let screen = screens[index]
        // Cheap bail-out for the usual case: nowhere near the top.
        guard location.y >= screen.frame.maxY - 80,
              let viewModel = viewModelForScreen?(screen)
        else { return }

        let trigger = SnapZones.trigger(
            screenFrame: screen.frame,
            closedNotchSize: viewModel.closedNotchSize,
            menuBarHeight: getMenuBarHeight(for: screen)
        )
        guard trigger.contains(location) else { return }
        showPicker(on: screen, viewModel: viewModel)
    }

    /// The tile under `location`, if the picker's grid is on screen.
    private func layout(at location: CGPoint, on screen: NSScreen) -> SnapLayout? {
        // The menu bar is where macOS's own fill-the-screen tiling listens;
        // tiles only count once the cursor is below it.
        guard location.y < screen.visibleFrame.maxY,
              let view = gridView,
              let window = view.window
        else { return nil }
        let gridFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return SnapPickerGrid.layout(at: location, gridScreenFrame: gridFrame)
    }

    private func setHoveredLayout(_ layout: SnapLayout?) {
        guard layout != hoveredLayout else { return }
        hoveredLayout = layout
        if layout != nil, Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: - Picker

    private func showPicker(on screen: NSScreen, viewModel: NotchViewModel) {
        let coordinator = NotchCoordinator.shared
        guard !coordinator.firstLaunch, !coordinator.helloAnimationRunning else { return }
        if viewModel.notchState == .closed {
            guard viewModel.open() else { return }
        }
        // Holds the notch open: hover events don't arrive mid-drag, and a
        // stale hover-exit mustn't close it under the cursor.
        viewModel.isPopoverActive = true
        pickerViewModel = viewModel
        pickerScreen = screen
        hoveredLayout = nil
        pickerOwner = ObjectIdentifier(viewModel)
    }

    private func hidePicker() {
        // Runs on every mouse-up; writing even an unchanged value to an
        // observed property would redraw the notch each time.
        guard pickerOwner != nil || pickerViewModel != nil else { return }
        let viewModel = pickerViewModel
        pickerViewModel = nil
        pickerScreen = nil
        hoveredLayout = nil
        pickerOwner = nil
        guard let viewModel else { return }
        viewModel.isPopoverActive = false
        viewModel.close()
    }

    // MARK: - Snapping

    private func snap(_ window: TrackedWindow, to layout: SnapLayout, on screen: NSScreen) {
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return }
        let frame = ScreenCoordinates.flip(layout.frame(in: screen.visibleFrame), primaryScreenHeight: primaryHeight)
        Task {
            let snapped = await NotchHelperClient.shared.snapWindow(window.id, ownerPID: window.ownerPID, to: frame)
            if !snapped {
                Log.window.notice("Couldn't snap window \(window.id, privacy: .public) to \(layout.rawValue, privacy: .public)")
            }
        }
    }
}

#if DEBUG
extension WindowSnapController {
    /// Demo mode: open the layout grid as if a window were being dragged in,
    /// with one layout highlighted.
    func demoShowPicker(on screen: NSScreen, viewModel: NotchViewModel, highlighting layout: SnapLayout) {
        showPicker(on: screen, viewModel: viewModel)
        hoveredLayout = layout
    }

    func demoHidePicker() {
        guard pickerOwner != nil else { return }
        hidePicker()
    }
}
#endif
