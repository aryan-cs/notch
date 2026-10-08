//
//  FaceUnlockOverlay.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Face ID box shown on the REAL lock screen while face unlock is watching.
//  It rides the same private SkyLight space the notch uses to draw on the lock
//  screen (SkyLightOperator.delegateWindow). The window is transparent, ignores
//  mouse events, and never becomes key, so the password field keeps focus and
//  the user can always type instead.
//

import AppKit
import SkyLightWindow
import SwiftUI

/// Centered Face ID box over the lock screen, bound to the manager's state.
private struct FaceUnlockLockScreenOverlay: View {
    @ObservedObject var manager = FaceUnlockManager.shared

    var body: some View {
        ZStack {
            Color.clear
            FaceIDAnimationView(state: manager.animationState)
                .frame(width: 200, height: 200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

@MainActor
final class FaceUnlockOverlayController {
    private var window: NSWindow?

    func show() {
        guard window == nil else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.canBecomeVisibleWithoutLogin = true   // as SkyLightWindow's own lock-screen window
        panel.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: FaceUnlockLockScreenOverlay())
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(panel)
        window = panel
        Log.faceUnlock.notice("overlay shown: window=\(panel.windowNumber) frame=\(NSStringFromRect(panel.frame), privacy: .public) visible=\(panel.isVisible) onScreen=\(panel.occlusionState.contains(.visible))")
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
