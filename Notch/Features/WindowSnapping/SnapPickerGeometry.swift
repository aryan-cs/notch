//
//  SnapPickerGeometry.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Where things sit while a window is dragged to the notch: the tiles in
//  the picker, the zone that opens it and the zone that keeps it open.
//  While another app's window is being dragged our views get no hover
//  events, so the controller hit-tests the cursor against these itself.
//

import CoreGraphics

/// The picker's tiles, laid out once here for both the view that draws them
/// and the controller that hit-tests them.
enum SnapPickerGrid {
    /// Columns line up with where the window goes: the first three read
    /// left / middle / right, and the quarters sit in a 2×2 block of their
    /// own on the right.
    static let rows: [[SnapLayout]] = [
        [.leftHalf, .maximize, .rightHalf, .topLeftQuarter, .topRightQuarter],
        [.leftThird, .centerThird, .rightThird, .bottomLeftQuarter, .bottomRightQuarter]
    ]

    /// The wider gap that sets the quarters apart goes after this column.
    static let groupBreakAfterColumn = 2

    /// A display's 16:10, so each tile reads as a little screen.
    static let tileSize = CGSize(width: 96, height: 60)
    static let spacing: CGFloat = 8
    static let groupSpacing: CGFloat = 22

    private static var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// Space before `column`: none for the first, then the gap.
    private static func gap(before column: Int) -> CGFloat {
        guard column > 0 else { return 0 }
        return column == groupBreakAfterColumn + 1 ? groupSpacing : spacing
    }

    private static func minX(ofColumn column: Int) -> CGFloat {
        (0...column).reduce(0) { $0 + gap(before: $1) } + CGFloat(column) * tileSize.width
    }

    static var size: CGSize {
        CGSize(
            width: minX(ofColumn: columnCount - 1) + tileSize.width,
            height: CGFloat(rows.count) * tileSize.height + CGFloat(rows.count - 1) * spacing
        )
    }

    /// Each tile's frame in the grid's own space (origin top-left, y down).
    static let tileFrames: [SnapLayout: CGRect] = {
        var frames: [SnapLayout: CGRect] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (column, layout) in row.enumerated() {
                frames[layout] = CGRect(
                    origin: CGPoint(
                        x: minX(ofColumn: column),
                        y: CGFloat(rowIndex) * (tileSize.height + spacing)
                    ),
                    size: tileSize
                )
            }
        }
        return frames
    }()

    /// The tile under `point`, in grid space. Each tile claims half the gap
    /// around it, so the highlight doesn't flicker off while the cursor
    /// crosses from one tile to the next; past half a gap outside the grid
    /// there's no tile.
    static func layout(at point: CGPoint) -> SnapLayout? {
        for row in rows {
            for (column, layout) in row.enumerated() {
                guard let frame = tileFrames[layout] else { continue }
                let left = column == 0 ? spacing / 2 : gap(before: column) / 2
                let right = column == row.count - 1 ? spacing / 2 : gap(before: column + 1) / 2
                let claimed = CGRect(
                    x: frame.minX - left,
                    y: frame.minY - spacing / 2,
                    width: frame.width + left + right,
                    height: frame.height + spacing
                )
                // Half-open edges, so a point on a shared border has one owner.
                if point.x >= claimed.minX, point.x < claimed.maxX,
                   point.y >= claimed.minY, point.y < claimed.maxY {
                    return layout
                }
            }
        }
        return nil
    }

    /// The tile under a cursor at `screenPoint`, given where the grid is on
    /// screen. Both in AppKit coordinates (origin bottom-left). Scaled to the
    /// grid's nominal size, so a grid caught mid-animation still maps onto
    /// the right tiles.
    static func layout(at screenPoint: CGPoint, gridScreenFrame: CGRect) -> SnapLayout? {
        guard gridScreenFrame.width > 0, gridScreenFrame.height > 0 else { return nil }
        let point = CGPoint(
            x: (screenPoint.x - gridScreenFrame.minX) * size.width / gridScreenFrame.width,
            y: (gridScreenFrame.maxY - screenPoint.y) * size.height / gridScreenFrame.height
        )
        return layout(at: point)
    }
}

/// The areas around the notch a dragged window's cursor is tested against,
/// in AppKit coordinates. Both reach a point past the screen's top edge: a
/// cursor pinned against the top reports y == frame.maxY, which a rect
/// ending at maxY wouldn't contain.
enum SnapZones {
    /// The picker opens once the cursor is pushed up into the menu bar near
    /// the notch — past where the window itself stops — so moving a window
    /// to the top of the screen doesn't pop it open by accident.
    static func trigger(screenFrame: CGRect, closedNotchSize: CGSize, menuBarHeight: CGFloat) -> CGRect {
        let width = max(closedNotchSize.width + 2 * 60, 320)
        let height = max(closedNotchSize.height, menuBarHeight) + 4
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height + 1
        )
    }

    /// The picker stays up while the cursor is over the open notch or close
    /// to it; wider than the trigger, so it doesn't flap at the boundary.
    static func retain(screenFrame: CGRect, openNotchSize: CGSize) -> CGRect {
        let margin: CGFloat = 24
        let width = openNotchSize.width + 2 * margin
        let height = openNotchSize.height + margin
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height + 1
        )
    }

    /// Which of `screenFrames` holds `point`. A screen's own top edge counts
    /// (see above), unless a screen stacked on top of it holds the point
    /// outright.
    static func screenIndex(containing point: CGPoint, in screenFrames: [CGRect]) -> Int? {
        if let index = screenFrames.firstIndex(where: { $0.contains(point) }) {
            return index
        }
        return screenFrames.firstIndex { frame in
            point.y == frame.maxY && point.x >= frame.minX && point.x < frame.maxX
        }
    }
}

/// How a window's bounds changed between two looks during a mouse drag.
enum WindowMotion: Equatable {
    case unchanged
    /// Same size, new place: the drag is carrying the window.
    case moved
    /// The drag is resizing it instead.
    case resized

    init(from start: CGRect, to current: CGRect) {
        let tolerance: CGFloat = 0.5
        if abs(start.width - current.width) > tolerance || abs(start.height - current.height) > tolerance {
            self = .resized
        } else if abs(start.minX - current.minX) > tolerance || abs(start.minY - current.minY) > tolerance {
            self = .moved
        } else {
            self = .unchanged
        }
    }
}
