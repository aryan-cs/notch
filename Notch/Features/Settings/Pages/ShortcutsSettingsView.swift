//
//  ShortcutsSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
            } header: {
                Text("Notch")
            }
            Section {
                KeyboardShortcuts.Recorder("Open Clipboard History:", name: .openClipboardHistory)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Opens the notch on the clipboard tab. Needs clipboard history turned on.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle Sneak Peek:", name: .toggleSneakPeek)
            } header: {
                Text("Media")
            } footer: {
                Text(
                    "Sneak Peek shows the media title and artist under the notch for a few seconds."
                )
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .navigationTitle("Shortcuts")
    }
}
