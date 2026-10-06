//
//  SoftwareUpdater.swift
//  boringNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import AppKit
import SwiftUI

/// This fork's home. Its updates are published as GitHub releases; the
/// inherited Sparkle feed is upstream boring.notch's, whose builds would
/// replace this fork, so the updater is never started (see boringNotchApp).
enum NotchRepository {
    static let url = URL(string: "https://github.com/aryan-cs/notch")!
    static let latestRelease = URL(string: "https://github.com/aryan-cs/notch/releases/latest")!
    static let newIssue = "https://github.com/aryan-cs/notch/issues/new"
}

struct CheckForUpdatesView: View {
    var body: some View {
        Button("Check for Updates…") {
            NSWorkspace.shared.open(NotchRepository.latestRelease)
        }
    }
}

struct UpdaterSettingsView: View {
    var body: some View {
        Section {
            HStack {
                Text("New versions of Notch are posted on GitHub.")
                Spacer()
                Button("View Releases") {
                    NSWorkspace.shared.open(NotchRepository.latestRelease)
                }
            }
        } header: {
            Text("Software updates")
        }
    }
}
