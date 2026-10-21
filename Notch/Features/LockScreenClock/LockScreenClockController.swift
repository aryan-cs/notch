//
//  LockScreenClockController.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Puts the big clock on the lock screen while the Mac is locked. It's a
//  window above the lock screen (in the SkyLight space Face Unlock's box
//  uses, below that box), so it can't sit under the lock screen's own
//  controls; instead it asks NotchHelper what they are and leaves room for
//  them. macOS's own clock should be off (Clock Appearance → Never).
//

import AppKit
import Defaults
import SkyLightWindow
import SwiftUI

@MainActor
final class LockScreenClockController {
    static let shared = LockScreenClockController()

    private let model = LockScreenClockModel()
    private var window: NSWindow?
    private var controlsTask: Task<Void, Never>?

    /// How often to look for changes on the lock screen, like the password
    /// field appearing.
    private let controlsInterval: Duration = .seconds(1)
    /// About as long as macOS takes to fade the lock screen in and out.
    private let fadeIn: TimeInterval = 0.5
    private let fadeOut: TimeInterval = 0.35

    func screenLocked() {
        guard Defaults[.lockScreenClockEnabled], window == nil,
              let screen = NSScreen.screens.first   // the lock screen's controls are on the main display
        else { return }
        model.screenSize = screen.frame.size
        model.controls = []
        // Until the lock screen can be read, go by the setting.
        Task { [model] in
            if let shown = await NotchHelperClient.shared.lockScreenShowsUserNameAndPhoto() { model.showsPicture = shown }
        }

        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.canBecomeVisibleWithoutLogin = true
        // Below Face Unlock's box (Int32.max - 2), which shares the space.
        panel.level = NSWindow.Level(rawValue: Int(Int32.max) - 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: LockScreenClockView(model: model))
        panel.setFrame(screen.frame, display: true)
        // Fade in with the lock screen rather than before it.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(panel)
        NSAnimationContext.runAnimationGroup { $0.duration = fadeIn; panel.animator().alphaValue = 1 }
        window = panel
        watchControls()
        Log.app.notice("lock screen clock shown")
    }

    func screenUnlocked() {
        controlsTask?.cancel()
        controlsTask = nil
        guard let panel = window else { return }
        window = nil
        // Fade out with the lock screen.
        NSAnimationContext.runAnimationGroup({ $0.duration = fadeOut; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func watchControls() {
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            while !Task.isCancelled {
                // Accessibility sometimes reports nothing for a moment; keep
                // what was last seen until it reports something again.
                if let controls = await NotchHelperClient.shared.lockScreenControls(), !controls.isEmpty,
                   let self, controls != self.model.controls {
                    self.model.controls = controls
                    // Before the password field appears: is the name there,
                    // above the "Touch ID or Enter Password" line?
                    // macOS doesn't always follow the setting, so the picture's
                    // cutout goes by this; the picture stays when the field replaces the name.
                    if !controls.contains(where: { $0.kind == .field }) {
                        let showsName = controls.filter { $0.kind == .text }.count >= 2
                        self.model.showsPicture = showsName
                        Defaults[.lockScreenShowedName] = showsName
                    }
                }
                try? await Task.sleep(for: self?.controlsInterval ?? .seconds(1))
            }
        }
    }
}
