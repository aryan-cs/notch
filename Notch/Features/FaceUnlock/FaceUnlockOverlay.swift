//
//  FaceUnlockOverlay.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Face ID box shown on the REAL lock screen while face unlock is watching,
//  and on the desktop when Face Unlock approves sudo or a Touch ID prompt.
//  It rides the same private SkyLight space the notch uses to draw on the lock
//  screen (SkyLightOperator.delegateWindow). The window is transparent, ignores
//  mouse events, and never becomes key, so the password field keeps focus and
//  the user can always type instead.
//

import AppKit
import SkyLightWindow
import SwiftUI

/// The Face ID box, bound to the manager's state: in the middle of the
/// screen, or at `center` (in the overlay's top-left-origin coordinates).
private struct FaceUnlockLockScreenOverlay: View {
    @ObservedObject var manager = FaceUnlockManager.shared
    var center: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            FaceIDAnimationView(state: manager.animationState)
                .frame(width: Self.boxSize, height: Self.boxSize)
                .position(center ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    static let boxSize: CGFloat = 200
}

@MainActor
final class FaceUnlockOverlayController {
    private var window: NSWindow?

    /// Shows the box in the middle of the screen, or, with `frame` (another
    /// window, in top-left-origin screen coordinates), just above it.
    func show(beside frame: CGRect? = nil) {
        guard window == nil else { return }
        let screen = frame.flatMap(Self.screen(containing:))
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
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
        let center = frame.map { Self.boxCenter(beside: $0, on: screen) }
        panel.contentViewController = NSHostingController(rootView: FaceUnlockLockScreenOverlay(center: center))
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

    private static func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.cgDisplayID.map { CGDisplayBounds($0).contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? false
        }
    }

    /// Above the window if there's room, otherwise below it.
    private static func boxCenter(beside frame: CGRect, on screen: NSScreen) -> CGPoint {
        let display = screen.cgDisplayID.map(CGDisplayBounds) ?? .zero
        let local = frame.offsetBy(dx: -display.minX, dy: -display.minY)
        let half = FaceUnlockLockScreenOverlay.boxSize / 2
        let above = local.minY - 8 - half
        let y = above - half >= 0 ? above : local.maxY + 8 + half
        return CGPoint(x: local.midX, y: y)
    }
}
