//
//  FullscreenMediaDetector.swift
//  Notch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Combine
import Defaults
import Foundation
import MacroVisionKit

/// Which screens should hide the closed notch's media display (the album art
/// and visualizer beside the notch) because something is full screen there.
/// With "Hide for media app only" that's when the full-screen app is the one
/// playing.
@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]

    private var monitorTask: Task<Void, Never>?
    private var spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        startMonitoring()
        // The playing app can change while a space stays full screen, as when
        // you go full screen and then press play, so look again then too.
        MusicManager.shared.$bundleIdentifier
            .removeDuplicates()
            .sink { [weak self] bundleIdentifier in self?.updateStatus(nowPlaying: bundleIdentifier) }
            .store(in: &cancellables)
        Defaults.publisher(.hideNotchOption, options: [])
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
            .store(in: &cancellables)
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                self.spaces = spaces
                updateStatus()
            }
        }
    }

    private func updateStatus(nowPlaying: String? = MusicManager.shared.bundleIdentifier) {
        var newStatus: [String: Bool] = [:]
        for space in spaces {
            guard let uuid = space.screenUUID else { continue }
            if Defaults[.hideNotchOption] == .nowPlayingOnly, let nowPlaying {
                newStatus[uuid] = space.runningApps.contains { Self.isSameApp($0, nowPlaying) }
            } else {
                newStatus[uuid] = true
            }
        }
        guard newStatus != fullscreenStatus else { return }
        Log.app.notice("full screen media hidden on \(newStatus.filter(\.value).count) of \(newStatus.count) full-screen spaces (playing: \(nowPlaying ?? "nothing", privacy: .public))")
        fullscreenStatus = newStatus
    }

    /// An app's helpers and web-app shims (com.google.Chrome.app.…) count as
    /// the app itself.
    static func isSameApp(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }
}
