//
//  ClipboardSettingsView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults
import SwiftUI

private struct IgnoredApp: Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

struct ClipboardSettingsView: View {
    @Default(.clipboardHistory) private var clipboardHistory
    @Default(.clipboardHistoryLimit) private var historyLimit
    @Default(.clipboardPasteOnSelect) private var pasteOnSelect
    @Default(.clipboardIgnoredApps) private var ignoredApps
    @ObservedObject private var manager = ClipboardHistoryManager.shared
    @State private var isAccessibilityAuthorized = true
    @State private var isConfirmingClear = false

    private static let limitOptions = [25, 50, 100, 200, 500]

    private var ignoredAppList: [IgnoredApp] {
        ignoredApps
            .map { IgnoredApp(bundleID: $0, name: displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .clipboardHistory) {
                    Text("Enable clipboard history")
                }
                Picker("History size", selection: $historyLimit) {
                    ForEach(Self.limitOptions, id: \.self) { limit in
                        Text("\(limit) items").tag(limit)
                    }
                }
                .disabled(!clipboardHistory)
                Defaults.Toggle(key: .clipboardPersistHistory) {
                    Text("Keep history after quitting")
                }
                .disabled(!clipboardHistory)
            } header: {
                Text("General")
            } footer: {
                Text("Pinned items don't count toward the history size. Copies that password managers mark as private are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .clipboardPasteOnSelect) {
                    Text("Paste into the active app when you choose an item")
                }
                .disabled(!clipboardHistory)

                if pasteOnSelect && !isAccessibilityAuthorized {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: AccessibilityPermission.systemImageName)
                            .font(.title)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(AccessibilityPermission.displayName) Required")
                                .font(.headline)
                            Text("Grant \(AccessibilityPermission.displayName) so Notch can paste for you. Until then, choosing an item only copies it.")
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
                Text("Choosing an Item")
            } footer: {
                Text("When off, choosing an item puts it back on the clipboard so you can paste it with ⌘V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if ignoredAppList.isEmpty {
                    Text("No apps ignored")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignoredAppList) { app in
                        HStack {
                            appIcon(for: app.bundleID)
                                .resizable().scaledToFit()
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            Text(app.name)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                ignoredApps.remove(app.bundleID)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    chooseApplication()
                } label: {
                    Label("Add Application…", systemImage: "plus")
                }
            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("Nothing you copy while one of these apps is in front is recorded. Common password managers are always ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!clipboardHistory)

            Section {
                HStack {
                    Text(manager.entries.count == 1 ? "1 item" : "\(manager.entries.count) items")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(manager.isEmpty)
                }
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
        .confirmationDialog("Clear clipboard history?", isPresented: $isConfirmingClear) {
            Button("Clear Unpinned Items", role: .destructive) {
                manager.clear(keepingPinned: true)
            }
            Button("Clear Everything", role: .destructive) {
                manager.clear(keepingPinned: false)
            }
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

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK else { return }
            let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard !bundleIDs.isEmpty else { return }
            DispatchQueue.main.async {
                ignoredApps.formUnion(bundleIDs)
            }
        }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
