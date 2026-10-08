//
//  SnapLayout.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The regions a window can be snapped to from the notch, and the math that
//  turns one into a frame — in AppKit's bottom-left space for the screen it
//  lands on, and in the top-left space the Accessibility API moves windows in.
//

import CoreGraphics

enum SnapLayout: String, CaseIterable, Identifiable {
    case leftHalf
    case maximize
    case rightHalf
    case leftThird
    case centerThird
    case rightThird
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    var id: Self { self }

    /// The screen divided into an even grid, and the cells this layout
    /// covers. Rows count from the top.
    struct Span: Equatable {
        let columns: Int
        let rows: Int
        let column: Range<Int>
        let row: Range<Int>
    }

    var span: Span {
        switch self {
        case .leftHalf: Span(columns: 2, rows: 1, column: 0..<1, row: 0..<1)
        case .maximize: Span(columns: 1, rows: 1, column: 0..<1, row: 0..<1)
        case .rightHalf: Span(columns: 2, rows: 1, column: 1..<2, row: 0..<1)
        case .leftThird: Span(columns: 3, rows: 1, column: 0..<1, row: 0..<1)
        case .centerThird: Span(columns: 3, rows: 1, column: 1..<2, row: 0..<1)
        case .rightThird: Span(columns: 3, rows: 1, column: 2..<3, row: 0..<1)
        case .topLeftQuarter: Span(columns: 2, rows: 2, column: 0..<1, row: 0..<1)
        case .topRightQuarter: Span(columns: 2, rows: 2, column: 1..<2, row: 0..<1)
        case .bottomLeftQuarter: Span(columns: 2, rows: 2, column: 0..<1, row: 1..<2)
        case .bottomRightQuarter: Span(columns: 2, rows: 2, column: 1..<2, row: 1..<2)
        }
    }

    /// For VoiceOver; the picker itself shows icons only.
    var title: String {
        switch self {
        case .leftHalf: String(localized: "Left Half")
        case .maximize: String(localized: "Fill Screen")
        case .rightHalf: String(localized: "Right Half")
        case .leftThird: String(localized: "Left Third")
        case .centerThird: String(localized: "Center Third")
        case .rightThird: String(localized: "Right Third")
        case .topLeftQuarter: String(localized: "Top Left Quarter")
        case .topRightQuarter: String(localized: "Top Right Quarter")
        case .bottomLeftQuarter: String(localized: "Bottom Left Quarter")
        case .bottomRightQuarter: String(localized: "Bottom Right Quarter")
        }
    }

    /// The region inside `visibleFrame` — a screen's area without the menu
    /// bar and Dock, in AppKit coordinates (origin bottom-left, y up).
    ///
    /// Edges are rounded to whole points, so neighbouring layouts meet
    /// exactly instead of overlapping or leaving a sliver between windows
    /// when the screen doesn't divide evenly (2560 / 3).
    func frame(in visibleFrame: CGRect) -> CGRect {
        let span = span
        func x(_ column: Int) -> CGFloat {
            visibleFrame.minX + (visibleFrame.width * CGFloat(column) / CGFloat(span.columns)).rounded()
        }
        // Rows count down from the top edge.
        func y(_ row: Int) -> CGFloat {
            visibleFrame.maxY - (visibleFrame.height * CGFloat(row) / CGFloat(span.rows)).rounded()
        }
        let minX = x(span.column.lowerBound)
        let maxX = x(span.column.upperBound)
        let maxY = y(span.row.lowerBound)
        let minY = y(span.row.upperBound)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// AppKit puts the origin at the bottom-left of the primary display with y
/// growing up; CoreGraphics window bounds and the Accessibility API put it
/// at the top-left with y growing down. Same x, mirrored y — so one flip
/// converts either way.
enum ScreenCoordinates {
    /// `primaryScreenHeight` is the height of the display with the menu bar
    /// (`NSScreen.screens[0]`), whose bottom-left is AppKit's origin.
    static func flip(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func flip(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}
