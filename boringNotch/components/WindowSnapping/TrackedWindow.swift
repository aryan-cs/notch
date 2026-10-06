//
//  TrackedWindow.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Another app's window, as the window server lists it. Bounds, owner and
//  layer come without Screen Recording access (only titles are withheld)
//  and work from inside the sandbox, which is all that's needed to tell
//  whether a mouse drag is carrying a window.
//

import CoreGraphics
import Foundation

struct TrackedWindow: Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    /// Top-left-origin global coordinates, like the Accessibility API's.
    let bounds: CGRect
    let layer: Int
    let alpha: Double

    /// Reads one entry of `CGWindowListCopyWindowInfo`.
    init?(_ entry: [String: Any]) {
        guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { return nil }
        self.id = id
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = entry[kCGWindowLayer as String] as? Int ?? 0
        self.alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
    }

    init(id: CGWindowID, ownerPID: pid_t, bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
        self.id = id
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }

    /// The frontmost ordinary window (layer 0, visible) under `point` that
    /// belongs to someone else, from a front-to-back window list. Windows
    /// stacked above that layer — the menu bar, the Dock, our own notch —
    /// are skipped rather than trusted: if one of them took the click, the
    /// window found here simply won't move, and the drag is ignored.
    static func frontmost(at point: CGPoint, in windows: [TrackedWindow], excludingPID: pid_t) -> TrackedWindow? {
        windows.first { window in
            window.layer == 0
                && window.alpha > 0
                && window.ownerPID != excludingPID
                && window.bounds.contains(point)
        }
    }

    /// The window under `point` (top-left-origin global coordinates) right now.
    static func under(_ point: CGPoint) -> TrackedWindow? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return frontmost(
            at: point,
            in: list.compactMap(TrackedWindow.init),
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Where the window is now; nil once it's gone.
    func currentBounds() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first
        else { return nil }
        return TrackedWindow(entry)?.bounds
    }
}
