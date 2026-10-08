//
//  NowPlayingController.swift
//  Notch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

@MainActor
final class NowPlayingController: NowPlayingRuntimeControlling {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: MediaAppBundleID.appleMusic
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == MediaAppBundleID.appleMusic || bundleID == MediaAppBundleID.spotify
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == MediaAppBundleID.appleMusic
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier

        if bundleID == MediaAppBundleID.appleMusic {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }

        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void
    private let adapterScriptURL: URL
    private let adapterFrameworkPath: String

    let runtimeFailures: AsyncStream<Void>
    private let runtimeFailureContinuation: AsyncStream<Void>.Continuation

    private var streamSession: NowPlayingStreamSession?

    // MARK: - Initialization
    init() throws {
        let resources = try NowPlayingResources.load()

        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
        else {
            throw NowPlayingError.unavailable
        }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)
        adapterScriptURL = resources.adapterScriptURL
        adapterFrameworkPath = resources.adapterFrameworkPath

        let runtimeFailureChannel = AsyncStream.makeStream(of: Void.self)
        runtimeFailures = runtimeFailureChannel.stream
        runtimeFailureContinuation = runtimeFailureChannel.continuation
    }

    deinit {
        if let streamSession {
            Task { @MainActor in
                streamSession.stop()
            }
        }
        runtimeFailureContinuation.finish()
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }

    func toggleShuffle() async {
        // Spotify ignores MediaRemote's shuffle command; see syncSpotifyModes.
        if isSpotifyPlaying {
            playbackState.isShuffled.toggle()
            scheduleSpotifySync()
            return
        }
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }

    func toggleRepeat() async {
        // Spotify's own order: off → all → one → off.
        if isSpotifyPlaying {
            switch playbackState.repeatMode {
            case .off: playbackState.repeatMode = .all
            case .all: playbackState.repeatMode = .one
            case .one: playbackState.repeatMode = .off
            }
            scheduleSpotifySync()
            return
        }
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }

    // MARK: - Spotify shuffle and repeat

    /// Clicks change the buttons right away; Spotify gets the result once
    /// they settle, in one go. Sending each click as it came let replies
    /// overlap and left the buttons out of step with Spotify.
    private var spotifySync: Task<Void, Never>?
    private var isSyncingSpotify = false
    /// Spotify's AppleScript only says whether repeat is on, so all and one
    /// look the same; this remembers which one was set from here.
    private var spotifyRepeatSetHere: RepeatMode?

    private func scheduleSpotifySync() {
        isSyncingSpotify = true
        spotifySync?.cancel()
        spotifySync = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.syncSpotifyModes()
            if !Task.isCancelled { self.isSyncingSpotify = false }
        }
    }

    /// Sends the buttons' shuffle and repeat to Spotify, then shows what it
    /// reports back.
    private func syncSpotifyModes() async {
        let shuffle = playbackState.isShuffled
        let repeatMode = playbackState.repeatMode
        _ = try? await AppleScriptHelper.execute("tell application \"Spotify\" to set shuffling to \(shuffle)")
        guard !Task.isCancelled else { return }

        // Repeat goes through Spotify's own Repeat command (off → all → one),
        // pressed as many times as it takes; AppleScript can't set repeat-one.
        if let current = await spotifyRepeatMode() {
            let order: [RepeatMode] = [.off, .all, .one]
            let presses = (order.firstIndex(of: repeatMode)! - order.firstIndex(of: current)! + order.count) % order.count
            var pressedAll = true
            for _ in 0..<presses {
                guard await NotchHelperClient.shared.pressSpotifyPlaybackItem("Repeat") else {
                    pressedAll = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if pressedAll {
                spotifyRepeatSetHere = repeatMode
            } else {
                // No Accessibility: AppleScript can still do off and all.
                _ = try? await AppleScriptHelper.execute("tell application \"Spotify\" to set repeating to \(repeatMode != .off)")
                spotifyRepeatSetHere = repeatMode == .off ? .off : .all
            }
        }
        guard !Task.isCancelled else { return }
        await refreshSpotifyModes(force: true)
    }

    /// Spotify's repeat: off, or whichever of all/one was last set from here.
    private func spotifyRepeatMode() async -> RepeatMode? {
        guard let repeating = try? await AppleScriptHelper.execute("tell application \"Spotify\" to return repeating")?.booleanValue
        else { return nil }
        guard repeating else { return .off }
        return spotifyRepeatSetHere == .one ? .one : .all
    }

    private var isSpotifyPlaying: Bool {
        playbackState.bundleIdentifier == MediaAppBundleID.spotify
            && !NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.spotify).isEmpty
    }

    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)

        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == MediaAppBundleID.appleMusic {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == MediaAppBundleID.spotify {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.spotify)
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }

        playbackState.volume = clampedLevel
    }

    // MARK: - Runtime Stream Lifecycle
    func startRuntimeStream() {
        guard streamSession == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapterScriptURL.path, adapterFrameworkPath, "stream"]

        let session = NowPlayingStreamSession(
            process: process,
            onUpdate: { [weak self] update in
                await self?.handleAdapterUpdate(update)
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.streamSession = nil
                self.runtimeFailureContinuation.yield()
            }
        )
        streamSession = session
        session.start()
    }

    func stopRuntimeStream() {
        let session = streamSession
        streamSession = nil
        session?.stop()
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        let resolvedBundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        let captureBundleFallbackIdentifiers: [String]
        if diff {
            captureBundleFallbackIdentifiers =
                resolvedBundleIdentifier != self.playbackState.bundleIdentifier
                ? [resolvedBundleIdentifier]
                : self.playbackState.effectiveAudioCaptureBundleIdentifiers
        } else {
            captureBundleFallbackIdentifiers = [resolvedBundleIdentifier]
        }
        let captureBundleIdentifiers = Self.audioCaptureBundleIdentifiers(
            sourceBundleIdentifier: payload.bundleIdentifier,
            fallbackBundleIdentifiers: captureBundleFallbackIdentifiers
        )

        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)

        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        } else {
            newPlaybackState.artwork = self.playbackState.artwork
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = resolvedBundleIdentifier
        newPlaybackState.audioCaptureBundleIdentifiers = captureBundleIdentifiers

        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)

        // Clicks waiting to reach Spotify keep the buttons as they are.
        if resolvedBundleIdentifier == MediaAppBundleID.spotify, isSyncingSpotify {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        self.playbackState = newPlaybackState

        // Spotify doesn't report shuffle or repeat to Now Playing, so a full
        // update (like a new track) would reset both buttons to off. Ask it.
        if !diff, resolvedBundleIdentifier == MediaAppBundleID.spotify,
           payload.shuffleMode == nil || payload.repeatMode == nil {
            await refreshSpotifyModes()
        }
    }

    /// Reads Spotify's actual shuffle and repeat into the buttons, unless
    /// clicks are still on their way to it (`force` is the sync itself).
    private func refreshSpotifyModes(force: Bool = false) async {
        guard isSpotifyPlaying, force || !isSyncingSpotify,
              let shuffling = try? await AppleScriptHelper.execute("tell application \"Spotify\" to return shuffling")?.booleanValue,
              let repeatMode = await spotifyRepeatMode(),
              force || !isSyncingSpotify
        else { return }
        playbackState.isShuffled = shuffling
        playbackState.repeatMode = repeatMode
    }

    private func fetchFavoriteStateIfSupported() async {
        guard playbackState.bundleIdentifier == MediaAppBundleID.appleMusic else { return }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application "Music"
            try
                return favorited of current track
            on error
                return false
            end try
        end tell
        """
        if let result = try? await AppleScriptHelper.execute(script) {
            var updated = playbackState
            updated.isFavorite = result.booleanValue
            playbackState = updated
        }
    }
}

private extension NowPlayingController {
    static func audioCaptureBundleIdentifiers(
        sourceBundleIdentifier: String?,
        fallbackBundleIdentifiers: [String]
    ) -> [String] {
        let preferred = sourceBundleIdentifier.map { [$0] } ?? fallbackBundleIdentifiers
        return preferred.normalizedBundleIdentifiers
    }
}
