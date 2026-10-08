//
//  DropActionStrip.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The action targets beside the shelf while files are dragged over the
//  notch — Convert, Remove BG, Unzip, Zip, whichever fit the drag. Resting
//  on Convert for a moment swaps the row for its formats; leaving the row
//  swaps it back. A quick drop on Convert uses the first format.
//

import SwiftUI
import UniformTypeIdentifiers

struct DropActionStrip: View {
    let availability: DropActionAvailability
    let dropInteraction: DropInteractionState
    let onDrop: (DropAction, [NSItemProvider]) -> Void

    @State private var hoveredIndex: Int?
    @State private var showsFormats = false
    @State private var dwellTask: Task<Void, Never>?
    @State private var revertTask: Task<Void, Never>?

    static let tileWidth: CGFloat = 88
    static let spacing: CGFloat = 12
    private static let formatSpacing: CGFloat = 8
    private static let minimumFormatTileWidth: CGFloat = 64
    /// How long the pointer rests on Convert before its formats appear —
    /// long enough that passing over it on the way to another target doesn't.
    private static let formatDwell: Duration = .milliseconds(350)
    private static let formatRevertDelay: Duration = .milliseconds(400)
    static let acceptedTypes: [UTType] = [.fileURL, .image, .audiovisualContent, .data]

    /// The formats share the actions' width where they fit, so the swap
    /// doesn't move the row under the pointer; more formats than actions
    /// (three video formats over Convert and Zip) widen it a little rather
    /// than squeeze the tiles.
    static func width(for availability: DropActionAvailability, showingFormats: Bool = false) -> CGFloat {
        let actions = CGFloat(availability.actions.count)
        let actionsWidth = actions * tileWidth + max(actions - 1, 0) * spacing
        guard showingFormats else { return actionsWidth }
        let formats = CGFloat(availability.formats.count)
        return max(actionsWidth, formats * minimumFormatTileWidth + max(formats - 1, 0) * formatSpacing)
    }

    private var width: CGFloat {
        Self.width(for: availability, showingFormats: showsFormats)
    }

    private var tileCount: Int {
        showsFormats ? availability.formats.count : availability.actions.count
    }

    private var tileSpacing: CGFloat {
        showsFormats ? Self.formatSpacing : Self.spacing
    }

    var body: some View {
        ZStack {
            if showsFormats {
                row(spacing: Self.formatSpacing) {
                    ForEach(Array(availability.formats.enumerated()), id: \.element) { index, format in
                        DropActionTile(title: format.title, symbolName: format.symbolName, isTargeted: hoveredIndex == index)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                row(spacing: Self.spacing) {
                    ForEach(Array(availability.actions.enumerated()), id: \.element) { index, action in
                        DropActionTile(title: action.title, symbolName: action.symbolName, isTargeted: hoveredIndex == index)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        // One target for the whole row that hit-tests the pointer itself:
        // a per-tile target removed mid-hover (when the formats swap in)
        // never reports an exit, which would leave the drag looking
        // "still over the notch" after it had gone.
        .onDrop(of: Self.acceptedTypes, delegate: StripDropDelegate(
            entered: { setTargeting(true) },
            updated: hover(at:),
            exited: endHover,
            performed: perform(at:providers:)
        ))
        .onDisappear {
            dwellTask?.cancel()
            revertTask?.cancel()
            setTargeting(false)
        }
    }

    /// Drag updates arrive continuously; only report actual changes so the
    /// notch isn't re-rendered on every one.
    private func setTargeting(_ isTargeted: Bool) {
        if dropInteraction.actionTargeting != isTargeted {
            dropInteraction.actionTargeting = isTargeted
        }
    }

    private func row<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: spacing, content: content)
    }

    /// Tiles share the width evenly; each owns half the gap on either side.
    private func tileIndex(at x: CGFloat) -> Int {
        let count = tileCount
        guard count > 0 else { return 0 }
        let pitch = (width + tileSpacing) / CGFloat(count)
        return min(max(Int((x + tileSpacing / 2) / pitch), 0), count - 1)
    }

    private func hover(at location: CGPoint) {
        revertTask?.cancel()
        setTargeting(true)
        let index = tileIndex(at: location.x)
        guard index != hoveredIndex else { return }
        hoveredIndex = index

        dwellTask?.cancel()
        guard !showsFormats,
              availability.actions[index] == .convert,
              availability.formats.count > 1 else { return }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: Self.formatDwell)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) {
                showsFormats = true
            }
            // Picked up again from the next drag update, in the new layout.
            hoveredIndex = nil
        }
    }

    private func endHover() {
        dwellTask?.cancel()
        hoveredIndex = nil
        setTargeting(false)
        guard showsFormats else { return }
        revertTask = Task { @MainActor in
            try? await Task.sleep(for: Self.formatRevertDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) {
                showsFormats = false
            }
        }
    }

    private func perform(at location: CGPoint, providers: [NSItemProvider]) {
        let index = tileIndex(at: location.x)
        let action: DropAction
        if showsFormats {
            action = .convert(availability.formats[index])
        } else {
            switch availability.actions[index] {
            case .convert:
                guard let format = availability.formats.first else { return }
                action = .convert(format)
            case .removeBackground: action = .removeBackground
            case .unzip: action = .unzip
            case .zip: action = .zip
            }
        }
        endHover()
        // Keeps the notch open for the result card, as other shelf drops do.
        dropInteraction.dropEvent = true
        onDrop(action, providers)
    }
}

/// A drop target styled exactly like the shelf's AirDrop box and file panel.
struct DropActionTile: View {
    let title: String
    let symbolName: String
    let isTargeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                )

            ShelfDropZoneLabel(title: title, isTargeted: isTargeted, lineLimit: 1) {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.1), value: isTargeted)
    }
}

private struct StripDropDelegate: DropDelegate {
    let entered: () -> Void
    let updated: (CGPoint) -> Void
    let exited: () -> Void
    let performed: (CGPoint, [NSItemProvider]) -> Void

    func dropEntered(info: DropInfo) {
        entered()
        updated(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updated(info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        exited()
    }

    func performDrop(info: DropInfo) -> Bool {
        performed(info.location, info.itemProviders(for: DropActionStrip.acceptedTypes))
        return true
    }
}
