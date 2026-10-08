//
//  WindowSnapPickerView.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the open notch shows while a window is dragged into it: a grid of
//  little screens, each with the part a window would fill picked out. The
//  tile under the cursor lights up in the accent color; letting go there
//  snaps the window (see WindowSnapController).
//

import AppKit
import SwiftUI

/// Matches the notch's other cards.
private let tileCornerRadius: CGFloat = 12

struct WindowSnapPickerView: View {
    private let controller = WindowSnapController.shared

    var body: some View {
        // Its own height, not the space on offer: compact mode sizes the
        // open notch to its content.
        SnapLayoutGrid(hoveredLayout: controller.hoveredLayout)
            .background(SnapGridAnchor())
            .frame(maxWidth: .infinity)
    }
}

/// The tiles, placed exactly where SnapPickerGrid says — the controller
/// hit-tests against the same frames.
private struct SnapLayoutGrid: View {
    let hoveredLayout: SnapLayout?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(SnapLayout.allCases) { layout in
                if let frame = SnapPickerGrid.tileFrames[layout] {
                    SnapLayoutTile(layout: layout, isHovered: layout == hoveredLayout)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(
            width: SnapPickerGrid.size.width,
            height: SnapPickerGrid.size.height,
            alignment: .topLeading
        )
    }
}

/// A miniature screen with the part the window would fill drawn in, like
/// the icons in macOS's own Move & Resize menu.
private struct SnapLayoutTile: View {
    let layout: SnapLayout
    let isHovered: Bool

    private let inset: CGFloat = 6
    /// Between the cells of the layout's grid, so a half stops short of the
    /// middle and reads as a half rather than a slightly narrow window.
    private let cellGap: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: tileCornerRadius - inset, style: .continuous)
                .path(in: regionRect(in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: inset, dy: inset)))
                .fill(isHovered ? Color.effectiveAccent : Color.white.opacity(0.35))
        }
        .background(
            RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                .strokeBorder(isHovered ? Color.effectiveAccent.opacity(0.7) : .clear, lineWidth: 1.5)
        )
        .scaleEffect(isHovered ? 1.04 : 1)
        .animation(.smooth(duration: 0.15), value: isHovered)
        .accessibilityElement()
        .accessibilityLabel(Text(layout.title))
        .accessibilityAddTraits(isHovered ? .isSelected : [])
    }

    /// The cells the layout covers, in `area` divided into its grid.
    private func regionRect(in area: CGRect) -> CGRect {
        let span = layout.span
        let cellWidth = (area.width - cellGap * CGFloat(span.columns - 1)) / CGFloat(span.columns)
        let cellHeight = (area.height - cellGap * CGFloat(span.rows - 1)) / CGFloat(span.rows)
        return CGRect(
            x: area.minX + CGFloat(span.column.lowerBound) * (cellWidth + cellGap),
            y: area.minY + CGFloat(span.row.lowerBound) * (cellHeight + cellGap),
            width: CGFloat(span.column.count) * cellWidth + CGFloat(span.column.count - 1) * cellGap,
            height: CGFloat(span.row.count) * cellHeight + CGFloat(span.row.count - 1) * cellGap
        )
    }
}

/// Hands the grid's backing view to the controller, which converts its
/// frame to screen coordinates whenever it hit-tests: while another app's
/// window is being dragged, these views get no hover events of their own.
private struct SnapGridAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        WindowSnapController.shared.gridView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WindowSnapController.shared.gridView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        if WindowSnapController.shared.gridView === nsView {
            WindowSnapController.shared.gridView = nil
        }
    }
}
