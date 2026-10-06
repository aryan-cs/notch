//
//  PresenceSettingsView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Alert mode: enabling it (and the access it needs), how close counts, what
//  it's doing right now, and the two Focus shortcuts it runs.
//

import AppKit
import AVFoundation
import CoreBluetooth
import Defaults
import SwiftUI

struct PresenceSettingsView: View {
    @Default(.alertMode) private var enabled
    @Default(.presenceSensitivity) private var sensitivity
    @ObservedObject private var presence: PresenceGuard
    @ObservedObject private var bluetooth = BluetoothPermission.shared
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private static let shortcutsAppURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")

    init(presence: PresenceGuard = .shared) {
        self.presence = presence
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .alertMode) {
                    Text("Alert mode")
                }
                Picker("Sensitivity", selection: $sensitivity) {
                    Text("Low").tag(PresenceSensitivity.low)
                    Text("Medium").tag(PresenceSensitivity.medium)
                    Text("High").tag(PresenceSensitivity.high)
                }
                .pickerStyle(.segmented)
                .help("Higher notices devices farther away: about an arm's length on Low, 2–3 m on High.")
            } footer: {
                Text("The same switch as the shield button in the notch. While it's on and you're at your Mac, Bluetooth listens for Apple devices nearby. If more than usual come close, the camera checks for a second face, and Do Not Disturb stays on until they leave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enabled {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: stateSymbol)
                            .foregroundStyle(presence.state == .guarding ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        Text(stateTitle)
                        Spacer()
                        if isRunning {
                            Label("\(presence.nearCount)", systemImage: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                                .help(usualHelp)
                        }
                    }
                    Button {
                        presence.recalibrate()
                    } label: {
                        Label("Recalibrate", systemImage: "scope")
                    }
                    .disabled(!isRunning)
                } header: {
                    Text("Status")
                } footer: {
                    Text("Recalibrate while you're alone, so your own iPhone, Watch and AirPods count as usual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                accessRow("Bluetooth", systemImage: "dot.radiowaves.left.and.right", status: bluetoothAccess) {
                    if bluetooth.status == .notDetermined {
                        bluetooth.requestIfNeeded()
                    } else {
                        openPrivacySettings("Privacy_Bluetooth")
                    }
                }
                accessRow("Camera", systemImage: "camera", status: cameraAccess) {
                    if cameraStatus == .notDetermined {
                        requestCamera()
                    } else {
                        openPrivacySettings("Privacy_Camera")
                    }
                }
            } header: {
                Text("Access")
            } footer: {
                Text("The camera light comes on only during a check of about two seconds. Frames stay in memory and are never saved, and Bluetooth signals can't identify anyone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(FocusShortcut.allCases, id: \.self) { shortcut in
                    HStack(spacing: 8) {
                        Image(systemName: shortcut == .on ? "moon.fill" : "moon")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(shortcut.rawValue)
                        Spacer()
                        shortcutStatus(shortcut)
                    }
                }
                HStack {
                    Button {
                        NSWorkspace.shared.open(Self.shortcutsAppURL)
                    } label: {
                        Label {
                            Text("Open Shortcuts")
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Self.shortcutsAppURL.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await presence.refreshShortcuts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Check again")
                    .disabled(presence.isCheckingShortcuts)
                }
            } header: {
                Text("Focus Shortcuts")
            } footer: {
                Text("macOS doesn't let apps switch Focus, so alert mode runs two shortcuts you make in Shortcuts, each with one Set Focus action: \"Notch Focus On\" turns Do Not Disturb on, \"Notch Focus Off\" turns it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Alert Mode")
        .task {
            await presence.refreshShortcuts()
        }
        .onChange(of: enabled) { _, isEnabled in
            guard isEnabled else { return }
            requestCamera()
            bluetooth.requestIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Shortcuts or System Settings.
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if bluetooth.status != .notDetermined {
                bluetooth.requestIfNeeded()  // Only re-reads once it's been asked.
            }
            Task { await presence.refreshShortcuts() }
        }
    }

    // MARK: - Status

    private var isRunning: Bool {
        switch presence.state {
        case .watching, .checking, .guarding: true
        case .off, .paused: false
        }
    }

    private var stateSymbol: String {
        switch presence.state {
        case .off: "eye.slash"
        case .paused: "pause.circle"
        case .watching: "eye"
        case .checking: "camera.viewfinder"
        case .guarding: "moon.fill"
        }
    }

    private var stateTitle: LocalizedStringKey {
        switch presence.state {
        case .off: "Off — turn on Alert in the notch"
        case .paused: "Paused while you're away"
        case .watching: presence.usualCount == nil ? "Learning what's usual here…" : "Watching"
        case .checking: "Checking for a second face…"
        case .guarding: presence.turnedFocusOn ? "Someone's nearby — Do Not Disturb is on" : "Someone's nearby"
        }
    }

    private var usualHelp: String {
        guard let usual = presence.usualCount else { return "Apple devices close by" }
        return "Apple devices close by (usually \(usual))"
    }

    // MARK: - Access

    private enum Access {
        case allowed, notAsked, denied
    }

    private var bluetoothAccess: Access {
        if bluetooth.isAllowed { return .allowed }
        return bluetooth.isDenied ? .denied : .notAsked
    }

    private var cameraAccess: Access {
        switch cameraStatus {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private func accessRow(_ title: LocalizedStringKey, systemImage: String, status: Access, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            switch status {
            case .allowed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Allowed")
            case .notAsked:
                Button("Allow", action: action)
            case .denied:
                Button("Open System Settings", action: action)
            }
        }
    }

    private func requestCamera() {
        guard cameraStatus == .notDetermined else { return }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private func shortcutStatus(_ shortcut: FocusShortcut) -> some View {
        if let installed = presence.installedShortcuts {
            if installed.contains(shortcut) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Found")
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("Not found in Shortcuts")
            }
        } else if presence.isCheckingShortcuts {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("Couldn't check")
        }
    }
}
