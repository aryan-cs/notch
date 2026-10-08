//
//  ClipboardColorPickerButton.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The eyedropper in the clipboard tab's bottom-right corner. It's drawn as
//  a piece of the notch's black frame reaching into the tab, so cards
//  scrolling underneath look like they pass behind the frame.
//

import SwiftUI

struct ClipboardColorPickerButton: View {
    /// The tab's card corner radius. The fillets are those same corners
    /// cut out of the frame, so the content around the button keeps the
    /// cards' rounding.
    let filletRadius: CGFloat
    let isPicking: Bool
    let action: () -> Void

    /// How far the button reaches into the tab, fillets aside.
    static let size: CGFloat = 32
    private static let cornerRadius: CGFloat = 8

    @State private var isHovering = false

    private var isHighlighted: Bool { isHovering || isPicking }

    private var shape: FrameCornerShape {
        FrameCornerShape(cornerRadius: Self.cornerRadius, filletRadius: filletRadius)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "eyedropper.halffull")
                .font(.body)
                .foregroundStyle(isHighlighted ? .white : .gray)
                .frame(width: Self.size, height: Self.size)
                .background {
                    // The cards' hover brightness.
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .padding(4)
                        .opacity(isHighlighted ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // Room for the fillets, which curve out along the tab's edges.
        .padding([.top, .leading], shape.margin)
        .background { shape.fill(.black) }
        .animation(.smooth(duration: 0.2), value: isHighlighted)
        .help("Pick a color")
        .accessibilityLabel("Pick a color")
    }
}

/// A square in the bottom-trailing corner of `rect` with a rounded top-
/// leading corner and concave fillets flowing into the trailing and bottom
/// edges, like the notch's own ears flowing into the menu bar.
///
/// Built by cutting the content around the button out of the frame: the
/// content above it and beside it are rounded rectangles that run off past
/// `rect`, each ending in a rounded corner on the tab's edge. What's left
/// are those corners' complements, so the fillets are the cards' own
/// continuous corners, not an approximation of them.
private struct FrameCornerShape: Shape {
    var cornerRadius: CGFloat
    var filletRadius: CGFloat

    /// Room the fillets need above and beside the square: a continuous
    /// corner's curve runs about 1.53 times its radius along each edge.
    /// Whole points, so the square's edges stay on the pixel grid.
    var margin: CGFloat {
        (filletRadius * 1.52866).rounded(.up)
    }

    func path(in rect: CGRect) -> Path {
        let square = CGRect(
            x: rect.minX + margin, y: rect.minY + margin,
            width: rect.width - margin, height: rect.height - margin
        )
        // Far enough that the cut-outs' other corners are never inside rect.
        let far = rect.width + rect.height
        let above = CGRect(
            x: rect.minX - far, y: rect.minY - far,
            width: rect.width + far, height: square.minY - rect.minY + far
        )
        let beside = CGRect(
            x: rect.minX - far, y: rect.minY - far,
            width: square.minX - rect.minX + far, height: rect.height + far
        )
        let roundedSquare = Path(
            roundedRect: CGRect(x: square.minX, y: square.minY, width: square.width + far, height: square.height + far),
            cornerRadius: cornerRadius,
            style: .continuous
        )

        return Path(rect)
            .subtracting(Path(roundedRect: above, cornerRadius: filletRadius, style: .continuous))
            .subtracting(Path(roundedRect: beside, cornerRadius: filletRadius, style: .continuous))
            .subtracting(Path(square).subtracting(roundedSquare))
    }
}
