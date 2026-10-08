//
//  WindowSnappingSettingsSection.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The window snapping toggle, shown on the Notch settings page.
//

import AppKit
import Defaults
import SwiftUI

struct WindowSnappingSettingsSection: View {
    @Default(.windowSnapping) private var windowSnapping
    @State private var isAccessibilityAuthorized = true

    var body: some View {
        Section {
            Defaults.Toggle(key: .windowSnapping) {
                Text("Snap windows dragged to the notch")
            }

            if windowSnapping && !isAccessibilityAuthorized {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: AccessibilityPermission.systemImageName)
                        .font(.title)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(AccessibilityPermission.displayName) Required")
                            .font(.headline)
                        Text("Grant \(AccessibilityPermission.displayName) so Notch can move and resize other apps' windows.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Grant Access") {
                        Task {
                            isAccessibilityAuthorized = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                        }
                    }
                }
            }
        } header: {
            Text("Window Snapping")
        } footer: {
            Text("Drag a window up into the notch, then let go over a layout to fill that part of the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            isAccessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                isAccessibilityAuthorized = granted
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                isAccessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
            }
        }
    }
}
