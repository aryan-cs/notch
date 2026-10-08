//
//  MeetingLink.swift
//  Notch
//

import Foundation

/// A video-conferencing service recognised on calendar events.
enum MeetingProvider: String, Codable, CaseIterable, Sendable {
    case googleMeet
    case zoom
    case teams
    case webex
    case whereby
    case jitsi

    /// Human-readable name, used in the accessibility label.
    var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .whereby: return "Whereby"
        case .jitsi: return "Jitsi"
        }
    }

    /// Host suffixes that identify this provider. A host matches when it equals a
    /// suffix exactly or ends with "." + suffix, so `acme.zoom.us` matches `zoom.us`
    /// while `notzoom.us` does not.
    var hostSuffixes: [String] {
        switch self {
        case .googleMeet: return ["meet.google.com", "hangouts.google.com"]
        case .zoom: return ["zoom.us", "zoomgov.com"]
        case .teams: return ["teams.microsoft.com", "teams.live.com"]
        case .webex: return ["webex.com"]
        case .whereby: return ["whereby.com"]
        case .jitsi: return ["meet.jit.si"]
        }
    }

    static func provider(forHost host: String) -> MeetingProvider? {
        let host = host.lowercased()
        for provider in MeetingProvider.allCases {
            for suffix in provider.hostSuffixes where host == suffix || host.hasSuffix("." + suffix) {
                return provider
            }
        }
        return nil
    }
}

/// A join URL discovered on a calendar event, plus the service it belongs to.
struct MeetingLink: Equatable, Codable, Sendable {
    let url: URL
    let provider: MeetingProvider
}

extension MeetingLink {
    /// The join URL with Google's `authuser` hint, so a Meet link opens in `email`'s
    /// account instead of the browser's default Google account. Other providers,
    /// values that aren't email addresses and links that already pick an account are
    /// returned unchanged.
    func joinURL(googleAccount email: String) -> URL {
        // `+` (common in Gmail addresses) must be escaped or it decodes as a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        guard provider == .googleMeet,
              email.isLikelyEmailAddress,
              let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var queryItems = components.percentEncodedQueryItems ?? []
        guard !queryItems.contains(where: { $0.name.lowercased() == "authuser" }) else { return url }
        queryItems.append(URLQueryItem(name: "authuser", value: encodedEmail))
        components.percentEncodedQueryItems = queryItems
        return components.url ?? url
    }
}
