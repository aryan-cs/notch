//
//  TabSelectionView.swift
//  Notch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchTab
}

let tabs = [
    TabModel(label: "Home", icon: "music.note", view: .home),
    TabModel(label: "Calendar", icon: "calendar", view: .calendar),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Clipboard", icon: "list.clipboard.fill", view: .clipboard)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = NotchCoordinator.shared
    @Default(.showCalendar) private var showCalendar
    @Default(.shelfEnabled) private var shelfEnabled
    @Default(.clipboardHistory) private var clipboardHistory
    @Namespace var animation

    /// Home is always there; the others only when their feature is on.
    private var enabledTabs: [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .home: true
            case .calendar: showCalendar
            case .shelf: shelfEnabled
            case .clipboard: clipboardHistory
            case .devices: false  // a button on the header's right side instead
            }
        }
    }

    /// The bar has to fit left of the camera notch (~213pt in a 640pt
    /// notch); at 15pt a side five tabs need ~238pt and the last one hides
    /// under the notch, so busier bars pack tighter.
    private var tabPadding: CGFloat {
        enabledTabs.count >= 5 ? 10 : 15
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(enabledTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view, horizontalPadding: tabPadding) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    NotchHeader().environmentObject(NotchViewModel(camera: CameraModel()))
}
