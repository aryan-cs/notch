//
//  ClipboardHistoryView.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The clipboard tab: a horizontal strip of recent copies, pinned first.
//  Click a card to put it back on the clipboard (and, if enabled, paste it
//  into the app you were using). The eyedropper in the corner copies a
//  color from anywhere on screen.
//

import AppKit
import Defaults
import SwiftUI

/// Shared by the cards and the strip that scrolls them, so a card sliding
/// out of view is cut with the same rounded corner it has at rest.
private let cardCornerRadius: CGFloat = 12

struct ClipboardHistoryView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var manager = ClipboardHistoryManager.shared

    /// A freshly picked color, to scroll into view: it lands at the front,
    /// which may be off screen.
    @State private var pickedEntryID: UUID?

    var body: some View {
        Group {
            if manager.isEmpty {
                emptyState
            } else {
                // Cards are square: as wide as the tab is tall.
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 8) {
                                ForEach(manager.entries) { entry in
                                    ClipboardItemView(
                                        entry: entry,
                                        isRecentlySelected: manager.recentlySelectedID == entry.id,
                                        onSelect: { choose(entry) },
                                        onCopy: { choose(entry, as: $0) }
                                    )
                                    .frame(width: geometry.size.height, height: geometry.size.height)
                                    .id(entry.id)
                                }
                            }
                            // Lets the last card scroll out from under the
                            // eyedropper.
                            .padding(.trailing, ClipboardColorPickerButton.size + 8)
                        }
                        .scrollIndicators(.never)
                        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                        // Initial too: the first color picked into an empty
                        // history arrives along with the strip itself.
                        .onChange(of: pickedEntryID, initial: true) { _, id in
                            guard let id else { return }
                            withAnimation(.smooth) { proxy.scrollTo(id) }
                            pickedEntryID = nil
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            ClipboardColorPickerButton(
                filletRadius: cardCornerRadius,
                isPicking: manager.isPickingColor,
                action: pickColor
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.clipboard")
                .symbolVariant(.fill)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)

            Text("Things you copy will show up here")
                .foregroundStyle(.gray)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    private func choose(_ entry: ClipboardEntry, as text: String? = nil) {
        manager.select(entry, as: text)
        // Pasting means the user is done here; get out of the way.
        if Defaults[.clipboardPasteOnSelect] {
            vm.close()
        }
    }

    private func pickColor() {
        guard !manager.isPickingColor else { return }
        // The loupe leads the pointer out of the notch; hold it open so the
        // color lands where the user can see it.
        vm.isPopoverActive = true
        Task {
            if let entry = await manager.pickColor() {
                pickedEntryID = entry.id
                // Long enough to see its checkmark before the notch closes.
                try? await Task.sleep(for: .seconds(1.2))
            }
            vm.isPopoverActive = false
        }
    }
}

private struct ClipboardItemView: View {
    let entry: ClipboardEntry
    let isRecentlySelected: Bool
    let onSelect: () -> Void
    /// Copies another form of the entry, like a color's rgb().
    let onCopy: (String) -> Void

    @ObservedObject private var manager = ClipboardHistoryManager.shared
    @State private var isHovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(isHovering ? 0.12 : 0.06))
            // Clips image cards' edge-to-edge picture to the card's corners.
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(isRecentlySelected ? Color.effectiveAccent : .clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                controls
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if isRecentlySelected {
                    copiedIndicator
                        .padding(7)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onSelect)
            .contextMenu { contextMenu }
            .animation(.smooth(duration: 0.2), value: isHovering)
            .animation(.smooth(duration: 0.2), value: isRecentlySelected)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch entry.content {
        case .text(let string, _):
            if let color = entry.colorValue {
                colorPreview(color)
                    .accessibilityLabel(Text("Color, \(color.hex)"))
            } else {
                Group {
                    if let url = entry.linkURL {
                        linkPreview(url)
                    } else {
                        // No line limit: the card's height bounds it, and Text
                        // truncates with "…" at the last line that fits.
                        Text(Self.previewText(string))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .truncationMode(.tail)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

        case .image(_, _, let width, let height):
            imagePreview
                .accessibilityLabel(Text("Image, \(width) by \(height) pixels"))

        case .files(let urls):
            filesPreview(urls)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Fills the whole card, cropping whichever dimension overflows — no
    /// letterboxing. The clear base takes the card's size so the
    /// aspect-filled image can't push the layout wider.
    private var imagePreview: some View {
        Color.clear
            .overlay {
                if let thumbnail = manager.thumbnail(for: entry) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
            }
            .clipped()
    }

    /// A paint chip: the color on top, its hex below on the card's own
    /// surface, which stays legible whatever the color and lights up on
    /// hover like every other card.
    private func colorPreview(_ color: ClipboardColor) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if !color.isOpaque {
                    CheckerboardView()
                }
                Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                      blue: Double(color.blue) / 255, opacity: Double(color.alpha) / 255)
            }
            // Keeps a black swatch from vanishing into the notch; on
            // anything lighter it's invisible.
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: cardCornerRadius, topTrailingRadius: cardCornerRadius, style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }

            Text(color.hex)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        }
    }

    private func linkPreview(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(url.host(percentEncoded: false) ?? url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "link")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)

            // Long URLs have no spaces to wrap on; Text breaks them mid-word
            // and ends in "…" once the card runs out of room.
            Text(url.absoluteString)
                .font(.subheadline)
                .foregroundStyle(.gray)
                .truncationMode(.tail)
        }
    }

    private func filesPreview(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let first = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)

                // Middle truncation keeps the extension visible, like Finder.
                Text(first.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if urls.count > 1 {
                Text("+\(urls.count - 1) more")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Overlays

    /// Pin and delete while hovering; otherwise just a pin badge on pinned
    /// cards. Dark backing keeps them legible on top of images.
    @ViewBuilder
    private var controls: some View {
        if isHovering {
            HStack(spacing: 4) {
                controlButton(entry.isPinned ? "pin.slash.fill" : "pin.fill", help: entry.isPinned ? "Unpin" : "Pin") {
                    manager.togglePin(entry)
                }
                controlButton("xmark", help: "Delete") {
                    manager.remove(entry)
                }
            }
        } else if entry.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.effectiveAccent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .accessibilityLabel("Pinned")
        }
    }

    private func controlButton(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var copiedIndicator: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(checkColor, Color.effectiveAccent)
            .accessibilityLabel("Copied")
    }

    /// Black on a light accent (Multicolor with nothing playing is white),
    /// white otherwise, so the check never disappears into its circle.
    private var checkColor: Color {
        guard let accent = NSColor.effectiveAccent.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722 * accent.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if let color = entry.colorValue {
            Button("Copy Hex") { onCopy(color.hex) }
            Button("Copy RGB") { onCopy(color.rgb) }
            Button("Copy RGBA") { onCopy(color.rgba) }
            Button("Copy HSL") { onCopy(color.hsl) }
            Button("Copy SwiftUI Color") { onCopy(color.swiftUI) }
            Button("Copy NSColor") { onCopy(color.nsColor) }
            Divider()
        } else {
            Button("Copy") { onSelect() }
        }
        Button(entry.isPinned ? "Unpin" : "Pin") { manager.togglePin(entry) }
        Divider()
        Button("Delete", role: .destructive) { manager.remove(entry) }
        Button("Clear Unpinned History", role: .destructive) { manager.clear(keepingPinned: true) }
    }

    /// Long copies are trimmed before layout — Text measuring half a
    /// megabyte just to show a few lines makes scrolling stutter.
    private static func previewText(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
    }
}

/// What shows through a translucent color, as in every color picker.
private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.2)))
            for row in 0..<Int((size.height / tile).rounded(.up)) {
                for column in 0..<Int((size.width / tile).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    let square = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(square), with: .color(Color(white: 0.32)))
                }
            }
        }
        // The last row and column of squares overhang the edge.
        .clipped()
    }
}
