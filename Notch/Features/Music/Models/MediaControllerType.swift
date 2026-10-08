//
//  MediaControllerType.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Which source the music player follows (Settings → Media).
//

import Defaults
import Foundation

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying
    case appleMusic
    case spotify
    case youtubeMusic

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "nowPlaying", "Now Playing": self = .nowPlaying
        case "appleMusic", "Apple Music": self = .appleMusic
        case "spotify", "Spotify": self = .spotify
        case "youtubeMusic", "YouTube Music": self = .youtubeMusic
        default: return nil
        }
    }

    init?(nowPlayingBundleIdentifier bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Music":
            self = .appleMusic
        case "com.spotify.client":
            self = .spotify
        case YouTubeMusicConfiguration.default.bundleIdentifier:
            self = .youtubeMusic
        default:
            return nil
        }
    }

    var localizedResource: LocalizedStringResource {
        switch self {
        case .nowPlaying:
            "Now Playing"
        case .appleMusic:
            "Apple Music"
        case .spotify:
            "Spotify"
        case .youtubeMusic:
            "YouTube Music"
        }
    }

    var localizedString: String {
        String(localized: localizedResource)
    }
}
