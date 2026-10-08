//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Sparkle
import SwiftUI
import SwiftUIIntrospect

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case notch
    case appearance
    case media
    case calendar
    case shelf
    case clipboard
    case devices
    case mirror
    case faceUnlock
    case presence
    case battery
    case osd
    case notifications
    case shortcuts
    case about

    enum Icon {
        case system(String)
        case custom(String)
    }

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .appearance: "Appearance"
        case .media: "Media"
        case .calendar: "Calendar"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .devices: "Devices"
        case .mirror: "Mirror"
        case .faceUnlock: "Face Unlock"
        case .presence: "Alert Mode"
        case .battery: "Battery"
        case .osd: "OSD"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var icon: Icon {
        switch self {
        case .general: .system("gearshape")
        case .notch: .custom("notch")
        case .appearance: .system("circle.lefthalf.filled")
        case .media: .system("play.rectangle")
        case .calendar: .system("calendar")
        case .shelf: .system("tray.full")
        case .clipboard: .system("list.clipboard")
        case .devices: .system("headphones")
        case .mirror: .system("video")
        case .faceUnlock: .system("faceid")
        case .presence: .system("checkmark.shield")
        case .battery: .system("battery.100percent")
        case .osd: .system("sun.max")
        case .notifications: .system("bell.badge")
        case .shortcuts: .system("keyboard")
        case .about: .system("info.circle")
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?
    let camera: CameraModel

    init(updaterController: SPUStandardUpdaterController? = nil, camera: CameraModel) {
        self.updaterController = updaterController
        self.camera = camera
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    tabItem(tab)
                }
            }
            .listStyle(SidebarListStyle())
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettings()
                case .notch:
                    NotchSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .media:
                    MediaSettingsView()
                case .notifications:
                    NotificationSettingsView()
                case .calendar:
                    CalendarSettings()
                case .osd:
                    OSDSettings()
                case .battery:
                    BatterySettingsView()
                case .shelf:
                    ShelfSettingsView()
                case .clipboard:
                    ClipboardSettingsView()
                case .devices:
                    DevicesSettingsView()
                case .mirror:
                    WebcamSettingsView(camera: camera)
                case .faceUnlock:
                    FaceUnlockSettingsView()
                case .presence:
                    PresenceSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .about:
                    if let controller = updaterController {
                        AboutView(updaterController: controller)
                    } else {
                        // Fallback with a default controller
                        AboutView(
                            updaterController: SPUStandardUpdaterController(
                                startingUpdater: false, updaterDelegate: nil,
                                userDriverDelegate: nil))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        // Without a height the window sized itself to almost nothing.
        .frame(minHeight: 480, idealHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
        .id(accentColorUpdateTrigger)
#if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .notchDemoSettingsPage)) { note in
            if let page = (note.object as? String).flatMap(SettingsTab.init(rawValue:)) { selectedTab = page }
        }
#endif
        .onReceive(NotificationCenter.default.publisher(for: .accentColorChanged)) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }

    private func tabItem(_ tab: SettingsTab) -> some View {
        // Plain sidebar icons, which take the system accent like a native
        // sidebar.
        Label {
            Text(tab.title)
        } icon: {
            switch tab.icon {
            case .system(let name):
                Image(systemName: name)
            case .custom(let name):
                Image(name).renderingMode(.template)
            }
        }
        .tag(tab)
    }
}
