//
//  InlineOSD.swift
//  boringNotch
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import Defaults

struct InlineOSD: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var accent: Color?
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    var body: some View {
        HStack {
            // Icon only: it already says what's changing (and muted, via the
            // slash), so the name is left to VoiceOver.
            OSDIconView(eventType: type, icon: icon, value: value, accent: accent)
                .accessibilityLabel(osdTypeName(type))
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.notchSize.height - (hoverAnimation ? 0 : 12), alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            HStack {
                if type.isIconOnly {
                    Color.clear
                        .accessibilityLabel(value.isZero ? "Muted" : "Unmuted")
                } else {
                        HStack {
                        DraggableProgressBar(value: $value, onChange: { v in
                            if type == .volume {
                                VolumeManager.shared.setAbsolute(Float32(v))
                            } else if type == .brightness {
                                BrightnessManager.shared.setAbsolute(value: Float32(v))
                            }
                        }, accentColor: accent, compact: true)
                        .frame(maxWidth: .infinity)
                        if Defaults[.showClosedNotchOSDPercentage] && !(type == .volume && value.isZero) {
                            Text(value, format: .percent.precision(.fractionLength(0)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.closedNotchSize.height - (hoverAnimation ? 0 : 12), alignment: .center)
        }
        .frame(height: vm.closedNotchSize.height + (hoverAnimation ? 8 : 0), alignment: .center)
    }

    func osdTypeName(_ type: SneakContentType) -> String {
        switch type {
            case .volume:
                return NSLocalizedString("Volume", comment: "")
            case .brightness:
                return NSLocalizedString("Brightness", comment: "")
            case .backlight:
                return NSLocalizedString("Backlight", comment: "")
            case .mic:
                return NSLocalizedString("Mic", comment: "")
            default:
                return ""
        }
    }
}

#Preview {
    InlineOSD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), accent: .constant(nil), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(BoringViewModel(camera: CameraModel()))
}
