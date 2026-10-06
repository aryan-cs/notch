//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var clipboard = ClipboardHistoryManager.shared

    /// Same rule the shelf always had — tabs appear when there's something
    /// to switch to — extended to the calendar and clipboard tabs. The
    /// calendar always counts: it has no empty state to hide behind.
    private var showsTabs: Bool {
        let calendarEnabled = Defaults[.showCalendar]
        let shelfEnabled = Defaults[.boringShelf]
        let clipboardEnabled = Defaults[.clipboardHistory]
        guard calendarEnabled || shelfEnabled || clipboardEnabled else { return false }
        return coordinator.alwaysShowTabs
            || calendarEnabled
            || (shelfEnabled && !shelfState.isEmpty)
            || (clipboardEnabled && !clipboard.isEmpty)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if showsTabs {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                        OpenNotchOSD(
                             type: coordinator.binding(for: vm.screenUUID).type,
                             value: coordinator.binding(for: vm.screenUUID).value,
                             icon: coordinator.binding(for: vm.screenUUID).icon,
                             accent: coordinator.binding(for: vm.screenUUID).accent
                        )
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showMirror] && coordinator.currentView == .home {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        AlertModeButton()
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        // Devices sits with the other quick icons rather than
                        // in the tab bar, which has no room left of the notch.
                        if Defaults[.showDevicesTab] {
                            Button(action: {
                                withAnimation(.smooth) {
                                    coordinator.currentView = coordinator.currentView == .devices ? .home : .devices
                                }
                            }) {
                                Capsule()
                                    .fill(coordinator.currentView == .devices ? Color(nsColor: .secondarySystemFill) : .black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "headphones")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Devices")
                            .accessibilityLabel("Devices")
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                timeToDischarge: batteryModel.timeToDischarge,
                                maxAdapterWatts: batteryModel.maxAdapterWatts,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}

/// Arms and disarms Alert mode: while it's on, the presence guard watches
/// for someone else nearby and turns on Do Not Disturb. Off, it's fully off.
private struct AlertModeButton: View {
    @Default(.alertMode) private var alertMode

    var body: some View {
        Button {
            withAnimation(.smooth) { alertMode.toggle() }
        } label: {
            Capsule()
                .fill(alertMode ? Color(nsColor: .secondarySystemFill) : .black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: alertMode ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                        .contentTransition(.symbolEffect(.replace))
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help(alertMode ? "Alert mode on" : "Alert mode off")
        .accessibilityLabel("Alert mode")
        .accessibilityValue(alertMode ? "On" : "Off")
    }
}
