//
//  LockScreenSettingsView.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The lock screen: a preview of it, the big clock, and the macOS settings
//  that decide what else it shows (your name and photo, and macOS's own clock).
//

import AppKit
import Defaults
import SwiftUI

struct LockScreenSettingsView: View {
    @Default(.lockScreenClockEnabled) private var clockEnabled
    @Default(.lockScreenClockStyle) private var clockStyle
    @Default(.lockScreenClockHeight) private var clockHeight
    @Default(.lockScreenShowedName) private var lockScreenShowedName

    /// These are macOS's settings, read from (and changed through) NotchHelper;
    /// nil until it answers.
    @State private var showsNameAndPhoto: Bool?
    @State private var systemClockShown: Bool?
    @State private var isChangingNameAndPhoto = false
    @State private var nameAndPhotoError: String?

    var body: some View {
        Form {
            Section {
                // What the lock screen last showed beats what the setting says it should.
                LockScreenClockPreview(showsClock: clockEnabled, style: clockStyle, height: clockHeight,
                                       showsNameAndPhoto: lockScreenShowedName ?? showsNameAndPhoto ?? true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            clockSection
            macOSSection
        }
        .navigationTitle("Lock Screen")
        .task { await refreshSystemSettings() }
        // The macOS settings can change in System Settings while this is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSystemSettings() }
        }
    }

    private var clockSection: some View {
        Section {
            Toggle("Big clock", isOn: $clockEnabled)
            if clockEnabled {
                Picker("Glass", selection: $clockStyle) {
                    ForEach(LockScreenClockStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $clockHeight, in: 0.3...0.8, step: 0.05)
                        Text("\(Int((clockHeight * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                if systemClockShown == true {
                    HStack {
                        Text("macOS's own clock is still on, so you'll see both. Set Show large clock to Never in Clock Appearance.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Wallpaper Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                        }
                    }
                }
            }
        } header: {
            Text("Big Clock")
        } footer: {
            Text("A large clock across the lock screen, made of the glass macOS uses for its own clock: Dark or Light. Monogram and Control Center are other macOS glass. Size is how tall the digits are, as a share of the screen. Your name, photo and password field sit on top of it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var macOSSection: some View {
        Section {
            HStack {
                Toggle("Show your name and photo", isOn: Binding(
                    get: { showsNameAndPhoto ?? true },
                    set: { setShowsNameAndPhoto($0) }
                ))
                .disabled(showsNameAndPhoto == nil || isChangingNameAndPhoto)
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Open Lock Screen in System Settings")
            }
            if let nameAndPhotoError {
                Text(nameAndPhotoError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("macOS")
        } footer: {
            Text("The same as Show user name and photo in System Settings → Lock Screen. Changing it needs your Mac password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshSystemSettings() async {
        showsNameAndPhoto = await NotchHelperClient.shared.lockScreenShowsUserNameAndPhoto()
        systemClockShown = await NotchHelperClient.shared.isSystemLockScreenClockShown()
    }

    private func setShowsNameAndPhoto(_ shown: Bool) {
        guard !isChangingNameAndPhoto else { return }
        isChangingNameAndPhoto = true
        nameAndPhotoError = nil
        Task {
            let result = await NotchHelperClient.shared.setLockScreenShowsUserNameAndPhoto(shown)
            isChangingNameAndPhoto = false
            if !result.succeeded, let message = result.message { nameAndPhotoError = message }
            // Follow the setting until the next lock shows what macOS made of it.
            if result.succeeded { lockScreenShowedName = nil }
            await refreshSystemSettings()
        }
    }
}
