//
    //  SystemEventIndicatorModifier.swift
    //  boringNotch
    //
    //  Created by Richard Kunkli on 12/08/2024.
    //

import SwiftUI
import Defaults

struct SystemEventIndicatorModifier: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var eventType: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var accent: Color?
    var sendEventBack: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 14) {
            OSDIconView(eventType: eventType, icon: icon, value: value, accent: accent)
            if !eventType.isIconOnly {
                DraggableProgressBar(value: $value, onChange: sendEventBack, accentColor: accent)
                if Defaults[.showClosedNotchOSDPercentage] {
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } else {
                // The mic's slash already shows the state.
                Color.clear
                    .frame(width: 0)
                    .accessibilityLabel(value > 0 ? "Mic unmuted" : "Mic muted")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .imageScale(.large)
    }
}
