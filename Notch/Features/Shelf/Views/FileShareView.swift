//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    let dropInteraction: DropInteractionState
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false

    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? .systemShareMenu
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $interaction.dropZoneTargeting) { providers in
                interactionNonce = .init()
                interaction.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .onTapGesture {
                Task {
                    await handleClick()
                }
            }
    }

    private var dropArea: some View {
        ZStack {
            // Same outline as the file panel next to it (ShelfView).
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    dropInteraction.dropZoneTargeting
                        ? Color.accentColor.opacity(0.9)
                        : Color.white.opacity(0.1),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                )

            ShelfDropZoneLabel(title: selectedProvider.id, isTargeted: dropInteraction.dropZoneTargeting) {
                if let icon = quickShare.icon(for: selectedProvider.id, size: 40) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .resizable()
                        .scaledToFit()
                }
            }

            // Loading overlay
            if isProcessing || quickShare.isPickerOpen {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }

    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
