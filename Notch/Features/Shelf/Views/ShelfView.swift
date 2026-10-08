//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

struct ShelfView: View {
    let dropInteraction: DropInteractionState
    let animation: Animation?
    @StateObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject private var dropActionRunner = DropActionRunner.shared
    @Default(.shelfDropActions) private var dropActionsEnabled

    /// What the drop-action row offers for the drag in progress.
    @State private var dropActions: DropActionAvailability = .none
    @State private var showsDropActions = false
    @State private var hideDropActionsTask: Task<Void, Never>?

    private let spacing: CGFloat = 8

    private var displayedItems: [ShelfItem] {
        Defaults[.reverseShelfOrdering] ? Array(shelfState.items.reversed()) : shelfState.items
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        ShelfQuickLookHost { quickLookService in
            HStack(spacing: 12) {
                FileShareView(dropInteraction: dropInteraction)
                    .aspectRatio(1, contentMode: .fit)
                panel(quickLookService: quickLookService)
                    .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $interaction.dragDetectorTargeting) { providers in
                        handleDrop(providers: providers)
                    }
                if showsDropActions {
                    DropActionStrip(availability: dropActions, dropInteraction: dropInteraction) { action, providers in
                        dropActionRunner.perform(action, dropped: providers)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onChange(of: dropInteraction.anyDropZoneTargeting, initial: true) { _, isTargeted in
            updateDropActions(dragIsOverNotch: isTargeted)
        }
    }

    /// Shows the action row while files from elsewhere are dragged over the
    /// notch. Dragging a shelf item out doesn't count — the row would shrink
    /// the panel the drag started from.
    private func updateDropActions(dragIsOverNotch: Bool) {
        hideDropActionsTask?.cancel()
        let rowAnimation = animation ?? .smooth

        guard dragIsOverNotch else {
            // Crossing from one target to the next briefly reports none, so
            // wait a beat before deciding the drag has left.
            hideDropActionsTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                withAnimation(rowAnimation) {
                    showsDropActions = false
                }
            }
            return
        }

        guard !showsDropActions, dropActionsEnabled, !ShelfSelectionModel.shared.isDragging else { return }
        let availability = DropActionAvailability.forCurrentDrag()
        guard !availability.isEmpty else { return }
        dropActions = availability
        withAnimation(rowAnimation) {
            showsDropActions = true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !ShelfSelectionModel.shared.isDragging else { return false }
        dropInteraction.dropEvent = true
        shelfState.load(providers)
        return true
    }

    private func panel(quickLookService: QuickLookService) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                dropInteraction.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                ZStack {
                    ShelfBackgroundInteractionView()
                    content(quickLookService: quickLookService)
                        .padding()
                }
            }
            .transaction { transaction in
                transaction.animation = animation
            }
    }

    private func content(quickLookService: QuickLookService) -> some View {
        @Bindable var interaction = dropInteraction

        return Group {
            if shelfState.isEmpty && dropActionRunner.jobs.isEmpty {
                // One line: the panel narrows beside the drop actions mid-drag.
                ShelfDropZoneLabel(title: "Drop files here", isTargeted: dropInteraction.dragDetectorTargeting, lineLimit: 1) {
                    // Solid single color, like the AirDrop glyph beside it;
                    // hierarchical rendering drew the tray and arrow in two tones.
                    Image(systemName: "tray.and.arrow.down")
                        .resizable()
                        .scaledToFit()
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.monochrome)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: spacing) {
                            // Drop-action cards sit where their results will land.
                            if Defaults[.reverseShelfOrdering] { dropActionJobCards }
                            ForEach(displayedItems) { item in
                                ShelfItemView(
                                    item: item,
                                    quickLookService: quickLookService,
                                    dropInteraction: dropInteraction
                                )
                            }
                            if !Defaults[.reverseShelfOrdering] { dropActionJobCards }
                        }
                    }
                    .onChange(of: dropActionRunner.jobs.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.smooth) { proxy.scrollTo(id) }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $interaction.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            shelfState.cleanupInvalidItems()
        }
    }

    private var dropActionJobCards: some View {
        ForEach(dropActionRunner.jobs) { job in
            DropActionJobCard(job: job)
                .id(job.id)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

private struct ShelfBackgroundInteractionView: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView {
        BackgroundView()
    }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    static func dismantleNSView(_ nsView: BackgroundView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class BackgroundView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()

            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let contentView = window.contentView
            else { return }

            let hitPoint = contentView.convert(event.locationInWindow, from: nil)
            guard !isShelfItemInteraction(contentView.hitTest(hitPoint)) else { return }

            ShelfSelectionModel.shared.clear()
        }

        private func isShelfItemInteraction(_ hitView: NSView?) -> Bool {
            var view = hitView
            while let currentView = view {
                if currentView is any ShelfItemInteractionSurface {
                    return true
                }
                view = currentView.superview
            }
            return false
        }
    }
}

private struct ShelfQuickLookHost<Content: View>: View {
    @State private var service = QuickLookService()
    @ViewBuilder let content: (QuickLookService) -> Content

    var body: some View {
        content(service)
            .quickLookPresenter(using: service)
    }
}

/// Icon and caption for the shelf's drop targets — the AirDrop box, the
/// file panel and the drop actions — so all use one icon size, typeface,
/// color and spacing.
struct ShelfDropZoneLabel<Icon: View>: View {
    let title: String
    let isTargeted: Bool
    /// 1 where the box can get narrow beside others: a wrapped caption would
    /// lift its icon out of line with its neighbors', so it shrinks a touch
    /// to fit instead.
    var lineLimit = 2
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(spacing: 8) {
            icon()
                .frame(width: 20, height: 20)
                .foregroundStyle(isTargeted ? Color.accentColor : Color.gray)
                .scaleEffect(isTargeted ? 1.06 : 1.0)
                .animation(.spring(response: 0.36, dampingFraction: 0.7), value: isTargeted)

            // Same size and weight as the calendar and clipboard text.
            Text(title)
                .font(.callout)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
    }
}
