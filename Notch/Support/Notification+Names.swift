//
//  Notification+Names.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  In-app notifications posted through NotificationCenter.
//

import Foundation

extension Notification.Name {
    // MARK: - Display
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")

    // MARK: - Shelf
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")

    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")

    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("SharingDidFinish")

    // MARK: - UI
    static let accentColorChanged = Notification.Name("AccentColorChanged")
}
