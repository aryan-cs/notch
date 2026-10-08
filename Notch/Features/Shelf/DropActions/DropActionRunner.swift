//
//  DropActionRunner.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Runs drop actions for the shelf — from a drop on an action target or
//  from a shelf item's context menu — and keeps a card on the shelf for
//  each result while it's being made, or briefly if it failed. Finished
//  results join the shelf as temporary items.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DropActionRunner: ObservableObject {
    static let shared = DropActionRunner()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let action: DropAction
        /// What the result will be called.
        let name: String
        /// Set when the action failed; shown as the card's tooltip.
        var failure: String?
    }

    @Published private(set) var jobs: [Job] = []

    /// How long a failed card stays before clearing itself.
    private let failureDisplayDuration: Duration = .seconds(6)

    private init() {}

    /// Files dropped on an action target.
    func perform(_ action: DropAction, dropped providers: [NSItemProvider]) {
        // NSItemProvider isn't marked Sendable but loads from any thread;
        // nothing else touches these once the drop has handed them over.
        nonisolated(unsafe) let providers = providers
        Task {
            let dropped = await DroppedFiles.load(from: providers)
            guard !dropped.urls.isEmpty else {
                Log.shelf.error("Drop action \(String(describing: action)) got no files")
                reportFailure(of: action, DropActionError.noFiles)
                return
            }
            await perform(action, on: dropped.urls)
            dropped.removeCopies()
        }
    }

    /// Shelf items picked from the context menu.
    func perform(_ action: DropAction, on items: [ShelfItem]) {
        let urls = items.compactMap { ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: $0) }
        Task { await perform(action, on: urls) }
    }

    func perform(_ action: DropAction, on inputs: [URL]) async {
        guard !inputs.isEmpty else { return }

        // Shelf items are security-scoped bookmarks; dropped files don't need
        // this, and starting access on them is a harmless no-op.
        let accessing = inputs.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (url, started) in zip(inputs, accessing) where started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Every card goes up at once; the work then runs one at a time, since
        // Vision and video exports only slow each other down side by side.
        let groups = action.combinesInputs ? [inputs] : inputs.map { [$0] }
        let queued = groups.map { group in
            (job: Job(action: action, name: DropActionService.outputName(for: action, inputs: group)), inputs: group)
        }
        withAnimation(.smooth(duration: 0.25)) {
            jobs += queued.map(\.job)
        }

        for (job, group) in queued {
            do {
                let outputs = try await DropActionService.run(action, on: group)
                withAnimation(.smooth(duration: 0.25)) {
                    jobs.removeAll { $0.id == job.id }
                    addToShelf(outputs)
                }
            } catch {
                Log.shelf.error("Drop action \(String(describing: action)) failed: \(error.localizedDescription)")
                fail(job.id, with: error)
            }
        }
    }

    func dismiss(_ job: Job) {
        withAnimation(.smooth(duration: 0.25)) {
            jobs.removeAll { $0.id == job.id }
        }
    }

    /// A failure before there was a result to name, like a drop with no
    /// readable files: the card carries the action's name instead.
    private func reportFailure(of action: DropAction, _ error: Error) {
        let job = Job(action: action, name: action.kind.title)
        withAnimation(.smooth(duration: 0.25)) {
            jobs.append(job)
        }
        fail(job.id, with: error)
    }

    private func fail(_ id: Job.ID, with error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].failure = error.localizedDescription
        Task { [weak self, failureDisplayDuration] in
            try? await Task.sleep(for: failureDisplayDuration)
            guard let self, let job = self.jobs.first(where: { $0.id == id }) else { return }
            self.dismiss(job)
        }
    }

    private func addToShelf(_ urls: [URL]) {
        let items = urls.compactMap { url -> ShelfItem? in
            guard let bookmark = try? Bookmark(url: url) else { return nil }
            return ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
        }
        ShelfStateViewModel.shared.add(items)
    }
}

// MARK: - Dropped files

/// The files in a drop, as URLs an action can read.
private struct DroppedFiles {
    var urls: [URL] = []
    /// Files written for promised or raw-data drops (Photos, a browser
    /// image) so there was something on disk to act on.
    var copies: [URL] = []

    static func load(from providers: [NSItemProvider]) async -> DroppedFiles {
        var dropped = DroppedFiles()
        for provider in providers {
            if let url = await provider.extractFileURL(), url.isFileURL {
                dropped.urls.append(url)
            } else if let copy = await copyOfFileRepresentation(from: provider) {
                dropped.urls.append(copy)
                dropped.copies.append(copy)
            }
        }
        return dropped
    }

    func removeCopies() {
        for copy in copies {
            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: copy)
        }
    }

    /// Asks the provider for a file of its best file-like type and copies it
    /// out before the provider deletes its own.
    private static func copyOfFileRepresentation(from provider: NSItemProvider) async -> URL? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let fileLike = types.first { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) || $0.conforms(to: .archive) }
            ?? types.first { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }
        guard let type = fileLike else { return nil }

        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url, error == nil,
                      let directory = try? TemporaryFileStorageService.shared.createTempDirectory() else {
                    continuation.resume(returning: nil)
                    return
                }
                var name = suggestedName ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    name += ".\(ext)"
                }
                let copy = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
