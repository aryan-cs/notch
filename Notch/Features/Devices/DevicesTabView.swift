//
//  DevicesTabView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The devices tab: a card per Bluetooth device and audio output. Tap a
//  Bluetooth card to connect or disconnect it; tap the speaker on any audio
//  card to play sound there. Devices that report a level get battery rings
//  styled like Apple's Batteries widget.
//

import AppKit
import SwiftUI

/// Shared by the cards and their scrolling strip, like the clipboard tab.
private let deviceCardCornerRadius: CGFloat = 12

struct DevicesTabView: View {
    @StateObject private var model = NotchDevicesModel()
    @ObservedObject private var permission = BluetoothPermission.shared

    var body: some View {
        Group {
            if model.devices.isEmpty && !permission.isDenied {
                VStack(spacing: 8) {
                    Image(systemName: "headphones")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("No devices")
                        .font(.callout)
                        .foregroundStyle(.gray)
                }
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        // Eager, not lazy: there are only a handful of cards,
                        // and reorders (a new output moving to the front)
                        // animate as moves instead of disappear/appear.
                        HStack(spacing: 8) {
                            if permission.isDenied {
                                BluetoothAccessCard()
                                    .frame(width: geometry.size.height, height: geometry.size.height)
                            }
                            ForEach(model.devices) { device in
                                DeviceCard(
                                    device: device,
                                    isOutput: device.audioOutputID != nil && device.audioOutputID == model.activeOutputID,
                                    isBusy: model.busyIDs.contains(device.id),
                                    didFail: model.failedIDs.contains(device.id),
                                    onTap: { model.primaryAction(device) },
                                    onMakeOutput: { model.makeOutput(device) },
                                    onToggleConnection: {
                                        device.isConnected ? model.disconnect(device) : model.connect(device)
                                    }
                                )
                                .frame(width: geometry.size.height, height: geometry.size.height)
                                // The card heading to the front passes over
                                // the others rather than under them.
                                .zIndex(device.audioOutputID != nil && device.audioOutputID == model.activeOutputID ? 1 : 0)
                            }
                        }
                        .animation(.smooth(duration: 0.35), value: model.devices.map(\.id))
                    }
                    .scrollIndicators(.never)
                    .clipShape(RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// Leads the strip when Bluetooth access is off: outputs still work, but
/// paired devices can't be listed or connected until it's allowed.
private struct BluetoothAccessCard: View {
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(height: 24)
            Text("Bluetooth access is off")
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("Click to allow")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(isHovering ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct DeviceCard: View {
    let device: NotchDevice
    let isOutput: Bool
    let isBusy: Bool
    let didFail: Bool
    let onTap: () -> Void
    let onMakeOutput: () -> Void
    let onToggleConnection: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: device.systemImage)
                    .font(.title2)
                    .foregroundStyle(device.isConnected ? .white : .gray)
                    .frame(height: 24)
                Spacer(minLength: 0)
                if device.isConnected && device.audioOutputID != nil {
                    outputButton
                }
            }

            Text(device.name)
                .font(.callout)
                .foregroundStyle(device.isConnected ? .white : .gray)
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(isHovering ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous)
                .strokeBorder(isOutput ? Color.effectiveAccent : .clear, lineWidth: 2)
        )
        .overlay(alignment: .bottomTrailing) {
            status
                .padding(10)
        }
        .opacity(device.isConnected || isBusy ? 1 : 0.6)
        // Move and draw as one piece: otherwise the icon, name and rings each
        // animate (and layer) on their own when cards swap places.
        .geometryGroup()
        .compositingGroup()
        .contentShape(RoundedRectangle(cornerRadius: deviceCardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { contextMenu }
        .animation(.smooth(duration: 0.2), value: isHovering)
        .animation(.smooth(duration: 0.2), value: isOutput)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Connecting progress, or a failed connect, in the card's corner.
    @ViewBuilder
    private var status: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else if didFail {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Couldn't connect. Make sure it's on, nearby, and not connected to another device.")
                .accessibilityLabel("Couldn't connect")
        }
    }

    private var outputButton: some View {
        Button(action: onMakeOutput) {
            Image(systemName: isOutput ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOutput ? Color.effectiveAccent : .gray)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOutput ? "Playing here" : "Play sound here")
        .accessibilityLabel(isOutput ? "Current output" : "Play sound here")
    }

    @ViewBuilder
    private var footer: some View {
        // Disconnected devices are just dimmed (the tooltip says "Click to
        // connect"); progress and failure show in the corner (see status).
        // An unreachable phone keeps its last level (dimmed with the card).
        if (!device.isConnected && device.lastSeen == nil) || isBusy || didFail {
            EmptyView()
        } else if device.battery.left != nil || device.battery.right != nil || device.battery.caseLevel != nil {
            // Three rings (left, right, case) sit centered; fewer sit right.
            let ringCount = [device.battery.left, device.battery.right, device.battery.caseLevel].compactMap { $0 }.count
            let isPro: Bool = if case .earbuds(let symbol) = device.kind { symbol.hasPrefix("airpodspro") } else { false }
            HStack(spacing: ringCount >= 3 ? 6 : 8) {
                if let left = device.battery.left {
                    BatteryRing(level: left, caption: isPro ? "airpodpro.left" : "airpod.left")
                }
                if let right = device.battery.right {
                    BatteryRing(level: right, caption: isPro ? "airpodpro.right" : "airpod.right")
                }
                if let caseLevel = device.battery.caseLevel {
                    BatteryRing(level: caseLevel, caption: isPro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill")
                }
            }
            .frame(maxWidth: .infinity, alignment: ringCount >= 3 ? .center : .trailing)
            // Three rings are a little wider than the padded card.
            .padding(.horizontal, ringCount >= 3 ? -4 : 0)
        } else if let level = device.battery.single {
            BatteryRing(level: level, isCharging: device.battery.isCharging)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if device.bluetoothAddress != nil {
            Button(device.isConnected ? "Disconnect" : "Connect", action: onToggleConnection)
        }
        if device.isConnected && device.audioOutputID != nil && !isOutput {
            Button("Play Sound Here", action: onMakeOutput)
        }
        if let findMyURL {
            Button {
                // Find My has no public way to play a sound; open the device
                // there instead (or the app, if the link isn't handled).
                if !NSWorkspace.shared.open(findMyURL), let app = URL(string: "findmy://") {
                    NSWorkspace.shared.open(app)
                }
            } label: {
                Label("Open in Find My", systemImage: "location")
            }
        }
        Divider()
        Button("Bluetooth Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// iPhones, iPads and watches open on their own page in Find My (its
    /// `fmip1://device/device?sn=` link); AirPods and Beats open the app.
    private var findMyURL: URL? {
        if let serial = device.serialNumber,
           let encoded = serial.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "fmip1://device/device?sn=\(encoded)") {
            return url
        }
        let name = device.name.lowercased()
        guard device.isAppleDevice || name.contains("airpods") || name.contains("beats") else { return nil }
        return URL(string: "findmy://")
    }

    private var helpText: String {
        if let lastSeen = device.lastSeen {
            let ago = lastSeen.formatted(.relative(presentation: .named))
            return String(localized: "Last updated \(ago). Updates when it's on the same Wi-Fi and awake, or plugged in.")
        }
        if device.bluetoothAddress != nil && !device.isConnected {
            return String(localized: "Click to connect")
        }
        if device.audioOutputID != nil {
            return isOutput ? String(localized: "Playing here") : String(localized: "Click to play sound here")
        }
        if device.isAppleDevice {
            return String(localized: "Read over USB or Wi-Fi, about once a minute")
        }
        return String(localized: "Connected")
    }
}

/// Battery level drawn like a ring in Apple's Batteries widget: clockwise
/// from the top, green, or red at 20% and under unless charging; while
/// charging, a bolt sits in a break at the top. The percentage is inside and
/// an optional symbol (which bud, or the case) underneath.
private struct BatteryRing: View {
    let level: Int
    var caption: String? = nil
    var isCharging = false

    private let diameter: CGFloat = 36
    private let lineWidth: CGFloat = 4
    /// The break in the ring around the bolt.
    private var gap: CGFloat { lineWidth * 3 }

    private var color: Color {
        level <= 20 && !isCharging ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                ring
                Text("\(level)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)

            if let caption {
                Image(systemName: caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCharging ? "Battery \(level) percent, charging" : "Battery \(level) percent")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(level) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // Keep the stroke inside the frame.
        .padding(lineWidth / 2)
        .mask {
            ZStack(alignment: .top) {
                Rectangle()
                if isCharging {
                    Circle()
                        .frame(width: gap, height: gap)
                        .offset(y: lineWidth / 2 - gap / 2)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
        .overlay(alignment: .top) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: gap * 0.8, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: gap, height: gap)
                    .offset(y: lineWidth / 2 - gap / 2)
            }
        }
    }
}
