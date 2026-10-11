//
//  FaceUnlockDropDown.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face ID while you're using the Mac (approving sudo or a Touch ID prompt):
//  the notch grows down into a box holding the Face ID animation and folds
//  back up when it's done, the way the Dynamic Island does on an iPhone. The
//  lock screen keeps its centered box (FaceUnlockOverlay).
//
//  It's a window of its own, black like the notch and starting at exactly
//  the notch's size, so it reads as the notch itself changing shape. It
//  ignores the mouse and never takes the keyboard.
//

import AppKit
import SwiftUI

@MainActor
final class FaceUnlockDropDown {
    private let model = DropDownModel()
    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        model.notch = getClosedNotchSize(screenUUID: screen.displayUUID)
        let panel = window ?? makePanel()
        window = panel
        let size = DropDownView.panelSize(forNotch: model.notch)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        // Start at the notch's own size, then drop.
        model.isExpanded = false
        DispatchQueue.main.async { [model] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.isExpanded = true }
        }
    }

    /// Folds back into the notch, then goes away.
    func hide() {
        guard let panel = window else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { model.isExpanded = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, self?.model.isExpanded == false else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DropDownView.panelSize(forNotch: model.notch)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Above the notch's own window and the menu bar.
        panel.level = NSWindow.Level(rawValue: Int(Int32.max) - 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DropDownView(model: model))
        return panel
    }
}

@MainActor
private final class DropDownModel: ObservableObject {
    @Published var isExpanded = false
    @Published var notch = CGSize(width: 185, height: 32)
}

private struct DropDownView: View {
    @ObservedObject var model: DropDownModel
    @ObservedObject private var faceUnlock = FaceUnlockManager.shared

    /// How far below the notch it grows: room for the Face ID rings, and
    /// short enough to clear the Touch ID prompt that macOS puts just below.
    static let dropHeight: CGFloat = 140
    /// Bottom corners once it has dropped, rounder than the closed notch's.
    static let expandedBottomRadius: CGFloat = 32

    /// A little wider than the hardware notch, which would otherwise show
    /// at its sides. `notch` is 4 pt wider than the hardware, and the
    /// shape's flared top corners take `closed.top` off each side.
    static func width(forNotch notch: CGSize) -> CGFloat {
        notch.width + 2 * cornerRadiusInsets.closed.top + 4
    }

    static func panelSize(forNotch notch: CGSize) -> CGSize {
        CGSize(width: width(forNotch: notch) + 40, height: notch.height + dropHeight + 20)
    }

    var body: some View {
        let closed = cornerRadiusInsets.closed
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(
                    topCornerRadius: closed.top,
                    bottomCornerRadius: model.isExpanded ? Self.expandedBottomRadius : closed.bottom
                )
                .fill(.black)
                FaceIDAnimationView(state: faceUnlock.animationState)
                    .frame(width: Self.dropHeight, height: Self.dropHeight)
                    .padding(.top, model.notch.height)
                    .opacity(model.isExpanded ? 1 : 0)
            }
            // Notch-wide, so it reads as the notch itself growing down.
            .frame(width: Self.width(forNotch: model.notch),
                   height: model.notch.height + (model.isExpanded ? Self.dropHeight : 0),
                   alignment: .top)
            .clipped()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
