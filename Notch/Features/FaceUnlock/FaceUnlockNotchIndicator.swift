//
//  FaceUnlockNotchIndicator.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face ID while you're using the Mac (approving sudo or a Touch ID prompt):
//  the notch grows a small square on its right end, after whatever it's
//  showing (the album art and visualizer, say), with the Face ID animation
//  in it, and shrinks back when it's done. The lock screen keeps its
//  centered box (FaceUnlockOverlay).
//
//  NotchView draws the square inside the notch itself, so it's always on
//  top and always at the notch's current end; this only says when.
//

import SwiftUI

@MainActor
final class FaceUnlockNotchIndicator: ObservableObject {
    static let shared = FaceUnlockNotchIndicator()

    @Published private(set) var isShown = false

    func show() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { isShown = true }
    }

    func hide() {
        withAnimation(.spring(response: 0.26, dampingFraction: 1)) { isShown = false }
    }
}

/// The square: the Face ID animation, about as big as the album art the
/// notch shows on its left, with the same gap below it and to its right.
struct FaceUnlockNotchSquare: View {
    let height: CGFloat
    /// The rings' size, glow included.
    let iconSize: CGFloat
    @ObservedObject private var faceUnlock = FaceUnlockManager.shared

    /// The rings' outside diameter, glow included, in the animation's own
    /// 144 pt box (measured).
    private static let ringDiameter: CGFloat = 75

    static func width(forHeight height: CGFloat) -> CGFloat { height }

    var body: some View {
        let side = FaceIDAnimationLayerView.boxSide
        let closed = cornerRadiusInsets.closed
        let width = Self.width(forHeight: height)
        // The same gap below the rings and to their right. At the rings'
        // middle the notch's right edge is the top corner's flare in from its
        // outside, and this square ends the notch's right padding before it.
        let gap = (height - iconSize) / 2
        let offset = closed.bottom + width / 2 - closed.top - gap - iconSize / 2
        FaceIDAnimationView(state: faceUnlock.animationState)
            .frame(width: side * 1.25, height: side * 1.25)   // its own size, with room for the shadow
            .scaleEffect(iconSize / Self.ringDiameter)
            .frame(width: width, height: height)
            .offset(x: offset)
    }
}
