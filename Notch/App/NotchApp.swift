//
//  NotchApp.swift
//  Notch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
//  The app's entry point. Notch has no regular windows of its own: the
//  notch panels are created by NotchWindowManager, and the only scene here
//  is the menu bar item.
//

import Defaults
import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon

    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesButton()
            Button("Restart Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}
