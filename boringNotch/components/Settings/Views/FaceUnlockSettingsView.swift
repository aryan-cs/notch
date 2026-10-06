//
//  FaceUnlockSettingsView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock: the switch, setting up and trying your face, the Mac
//  password it enters for you, the access it needs, and lock-screen and
//  security options. The camera runs only while setting up or trying it here.
//

import AppKit
import AVFoundation
import Defaults
import SwiftUI

struct FaceUnlockSettingsView: View {
    @StateObject private var manager = FaceUnlockManager.shared
    @Default(.faceUnlockEnabled) private var enabled
    @Default(.faceUnlockThreshold) private var threshold
    @Default(.faceUnlockLiveness) private var liveness
    @Default(.faceUnlockRetryKey) private var retryKey
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    /// Nil until the first check comes back.
    @State private var accessibilityAllowed: Bool?
    @State private var passwordField = ""
    @State private var isChangingPassword = false

    var body: some View {
        Form {
            overviewSection
            faceSection
            passwordSection
            accessSection
            lockScreenSection
            securitySection
        }
        .formStyle(.grouped)
        .navigationTitle("Face Unlock")
        .onAppear {
            manager.refreshPasswordState()
            refreshAccess()
        }
        .onDisappear { manager.stop() }
        .onChange(of: enabled) { _, isEnabled in
            if isEnabled { requestCamera() }
        }
        .onChange(of: manager.isVerifyingPassword) { _, verifying in
            // A save finished: collapse back to "Password saved" if it worked.
            if !verifying, manager.passwordError == nil, manager.hasPassword { isChangingPassword = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()  // Back from System Settings.
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { note in
            if let granted = note.userInfo?["granted"] as? Bool { accessibilityAllowed = granted }
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        Section {
            Defaults.Toggle(key: .faceUnlockEnabled) {
                Text("Face Unlock")
            }
            if enabled, let missing = setupMissing {
                Label(missing, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Unlock your Mac by looking at it. When your screen locks, the camera looks for you for a few seconds. If it doesn't recognize you, type your password as usual\(retryHint).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var faceSection: some View {
        Section {
            facePreview
            if let error = manager.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !manager.status.isEmpty {
                Text(manager.status)
                    .foregroundStyle(.secondary)
            }
            if manager.activity == .enrolling {
                ProgressView(value: manager.enrollProgress)
            }
            faceButtons
        } header: {
            Text("Your Face")
        } footer: {
            Text("Set up in the lighting you usually work in. If Face Unlock has trouble somewhere darker or brighter, choose Improve Recognition while you're there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var passwordSection: some View {
        Section {
            if manager.hasPassword && !isChangingPassword {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                    Text("Password saved")
                    Spacer()
                    Button("Change") {
                        passwordField = ""
                        isChangingPassword = true
                    }
                    Button("Remove", role: .destructive) { manager.clearPassword() }
                }
            } else {
                SecureField("Mac password", text: $passwordField)
                    .onSubmit(savePassword)
                    .disabled(manager.isVerifyingPassword)
                HStack {
                    if manager.isVerifyingPassword {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isChangingPassword {
                        Button("Cancel") {
                            passwordField = ""
                            isChangingPassword = false
                        }
                    }
                    Button("Save Password", action: savePassword)
                        .disabled(passwordField.isEmpty || manager.isVerifyingPassword)
                }
            }
            if let error = manager.passwordError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Mac Password")
        } footer: {
            Text("When it recognizes you, Face Unlock enters your Mac password for you. It's checked against your account before it's saved, stays on this Mac where only your user account can read it, and is used only to unlock your screen. If you change your Mac password, update it here too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessSection: some View {
        Section {
            accessRow("Camera", systemImage: "camera", status: cameraAccess) {
                if cameraStatus == .notDetermined {
                    requestCamera()
                } else {
                    openPrivacySettings("Privacy_Camera")
                }
            }
            accessRow("Accessibility", systemImage: "accessibility", status: accessibilityAccess) {
                // Lists the app in Privacy & Security and offers to open it.
                XPCHelperClient.shared.requestAccessibilityAuthorization()
            }
        } header: {
            Text("Access")
        } footer: {
            Text("The camera turns on only while your screen is locked, or while you set up or try Face Unlock here. Nothing it sees is saved. Accessibility lets Face Unlock enter your password at the lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lockScreenSection: some View {
        Section {
            Picker("Try again", selection: $retryKey) {
                ForEach(FaceUnlockRetryKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("If Face Unlock doesn't recognize you, use this at the lock screen to have it look again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var securitySection: some View {
        Section {
            Picker("Photo protection", selection: $liveness) {
                ForEach(LivenessLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Slider(value: $threshold, in: 0.2...0.7) {
                Text("Matching")
            } minimumValueLabel: {
                Text("Easier").font(.caption)
            } maximumValueLabel: {
                Text("Stricter").font(.caption)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("\(livenessDescription) Stricter matching is harder for someone else to pass, but may need better lighting to recognize you. Face Unlock uses your Mac's regular camera, so treat it as a convenience: someone with a good video of you might get in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Your Face

    private var isUsingCamera: Bool {
        manager.activity == .enrolling || manager.activity == .testing
    }

    private var cameraBlocked: Bool {
        cameraStatus == .denied || cameraStatus == .restricted
    }

    private var facePreview: some View {
        ZStack(alignment: .bottomTrailing) {
            if isUsingCamera {
                FaceUnlockCameraPreview(session: manager.previewSession)
            } else {
                facePlaceholder
            }
            // Tucked into the corner so it never covers the face.
            FaceIDAnimationView(state: manager.animationState)
                .frame(width: 150, height: 150)
                .scaleEffect(1.0 / 3.0)
                .frame(width: 50, height: 50)
                .padding(10)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var facePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: cameraBlocked ? "video.slash" : "faceid")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(manager.isEnrolled && !cameraBlocked ? Color.accentColor : .secondary)
            Text(placeholderTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .quaternarySystemFill))
    }

    private var placeholderTitle: LocalizedStringKey {
        if cameraBlocked { return "Camera access is off" }
        return manager.isEnrolled ? "Your face is set up" : "Set up your face to use Face Unlock"
    }

    @ViewBuilder
    private var faceButtons: some View {
        HStack(spacing: 12) {
            if isUsingCamera {
                Button("Cancel", role: .cancel) { manager.stop() }
                ProgressView().controlSize(.small)
                Spacer()
            } else if manager.isEnrolled {
                Button("Try It") { manager.startTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cameraBlocked)
                Button("Improve Recognition") { manager.addSamples() }
                    .help("Add a few more looks at your face in the lighting you're in now.")
                    .disabled(cameraBlocked)
                Spacer()
                Menu {
                    Button("Set Up Again") { manager.startEnroll() }
                        .disabled(cameraBlocked)
                    Button("Remove Face", role: .destructive) { manager.unenroll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            } else {
                Button("Set Up Face") { manager.startEnroll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cameraBlocked)
                Spacer()
            }
        }
    }

    // MARK: - Setup state

    /// What's still needed before Face Unlock can work, most important first.
    private var setupMissing: LocalizedStringKey? {
        if !manager.isEnrolled { return "Set up your face below to start using Face Unlock." }
        if !manager.hasPassword { return "Add your Mac password below to start using Face Unlock." }
        if cameraStatus != .authorized { return "Allow camera access below." }
        if accessibilityAllowed == false { return "Allow Accessibility below so Face Unlock can enter your password." }
        return nil
    }

    /// ", or double-tap Right Shift to have it look again", per the chosen key.
    private var retryHint: String {
        guard retryKey != .off else { return "" }
        let action = retryKey.label.prefix(1).lowercased() + retryKey.label.dropFirst()
        return ", or \(action) to have it look again"
    }

    private var livenessDescription: String {
        switch liveness {
        case .off: "With photo protection off, a clear photo of you could unlock your Mac."
        case .standard: "Standard waits for a blink or a small head movement, so a photo of you won't work."
        case .strict: "Strict waits for a blink, which can take a moment longer."
        }
    }

    private func savePassword() {
        guard !passwordField.isEmpty, !manager.isVerifyingPassword else { return }
        manager.setPassword(passwordField)
        passwordField = ""
    }

    // MARK: - Access

    private enum Access {
        case allowed, notAsked, denied, unknown
    }

    private var cameraAccess: Access {
        switch cameraStatus {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private var accessibilityAccess: Access {
        switch accessibilityAllowed {
        case true?: .allowed
        case false?: .notAsked
        case nil: .unknown
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
            case .unknown:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func refreshAccess() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        Task { accessibilityAllowed = await XPCHelperClient.shared.isAccessibilityAuthorized() }
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
}

/// A live, mirrored view of the capture session, for aiming during setup.
private struct FaceUnlockCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            // Selfie mirror, display-only. Recognition uses the raw frames, so
            // this never affects matching.
            if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
    }
}
