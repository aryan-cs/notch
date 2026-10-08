//
//  SoftwareUpdates.swift
//  Notch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import AppKit
import SwiftUI

/// Notch's home on GitHub. New versions are published there as releases;
/// the app has no built-in updater.
enum NotchRepository {
    static let url = URL(string: "https://github.com/aryan-cs/notch")!
    static let latestRelease = URL(string: "https://github.com/aryan-cs/notch/releases/latest")!
    static let newIssue = "https://github.com/aryan-cs/notch/issues/new"
}

struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") {
            NSWorkspace.shared.open(NotchRepository.latestRelease)
        }
    }
}

struct SoftwareUpdatesSection: View {
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
