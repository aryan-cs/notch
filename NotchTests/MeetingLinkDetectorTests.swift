//
//  MeetingLinkDetectorTests.swift
//  boringNotchTests
//

import XCTest

@testable import Notch

final class MeetingLinkDetectorTests: XCTestCase {

    private func detect(url: String? = nil, location: String? = nil, notes: String? = nil) -> MeetingLink? {
        MeetingLinkDetector.detect(
            url: url.flatMap(URL.init(string:)),
            location: location,
            notes: notes
        )
    }

    // MARK: - Provider recognition

    func testGoogleMeetInNotes() {
        let link = detect(notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial in")
        XCTAssertEqual(link?.provider, .googleMeet)
        XCTAssertEqual(link?.url.host(), "meet.google.com")
    }

    func testZoomInLocation() {
        XCTAssertEqual(detect(location: "https://zoom.us/j/1234567890?pwd=xYz")?.provider, .zoom)
    }

    func testZoomVanitySubdomain() {
        let link = detect(location: "https://acme.zoom.us/j/999")
        XCTAssertEqual(link?.provider, .zoom)
        XCTAssertEqual(link?.url.host(), "acme.zoom.us")
    }

    func testTeamsAcrossNewlines() {
        let link = detect(notes: """
            Click here to join the meeting
            https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc
            Learn more
            """)
        XCTAssertEqual(link?.provider, .teams)
    }

    func testWebexSubdomain() {
        XCTAssertEqual(detect(location: "https://acme.webex.com/meet/x")?.provider, .webex)
    }

    func testJitsi() {
        XCTAssertEqual(detect(location: "https://meet.jit.si/StandUp")?.provider, .jitsi)
    }

    func testWhereby() {
        XCTAssertEqual(detect(location: "https://whereby.com/team")?.provider, .whereby)
    }

    func testLegacyHangoutsLink() {
        XCTAssertEqual(detect(url: "https://hangouts.google.com/hangouts/_/company.com/standup")?.provider, .googleMeet)
    }

    func testGoogleMeetShortLink() {
        XCTAssertEqual(detect(location: "g.co/meet/team-standup")?.provider, .googleMeet)
        XCTAssertEqual(detect(notes: "Join: https://g.co/meet/abc-defg-hij")?.provider, .googleMeet)
    }

    func testOtherGoogleShortLinksIgnored() {
        XCTAssertNil(detect(notes: "Agenda: https://g.co/kgs/abc123"))
    }

    // MARK: - Field priority

    func testURLFieldBeatsLocation() {
        let link = detect(url: "https://meet.google.com/aaa-bbbb-ccc", location: "https://zoom.us/j/111")
        XCTAssertEqual(link?.provider, .googleMeet)
    }

    func testLocationBeatsNotes() {
        let link = detect(location: "https://zoom.us/j/222",
                          notes: "Old link https://meet.google.com/zzz-yyyy-xxx")
        XCTAssertEqual(link?.provider, .zoom)
    }

    func testFirstKnownLinkWinsWithinAField() {
        let link = detect(notes: "https://example.com/x then https://whereby.com/team then https://zoom.us/j/1")
        XCTAssertEqual(link?.provider, .whereby)
    }

    // MARK: - Rejection

    func testUnknownHostIgnored() {
        XCTAssertNil(detect(notes: "Agenda: https://docs.google.com/document/d/abc123/edit"))
    }

    func testLookalikeHostRejected() {
        XCTAssertNil(detect(location: "https://notzoom.us/j/1"))
    }

    func testNonHTTPSchemeRejected() {
        XCTAssertNil(detect(url: "mailto:someone@zoom.us"))
    }

    func testAllFieldsNil() {
        XCTAssertNil(detect())
    }

    func testEmptyStrings() {
        XCTAssertNil(detect(location: "", notes: ""))
    }

    // MARK: - Google account hint

    private func authUser(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "authuser" }?.value
    }

    func testJoinURLAddsGoogleAccount() throws {
        let link = try XCTUnwrap(detect(notes: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(authUser(in: link.joinURL(googleAccount: "me@work.com")), "me@work.com")
    }

    func testJoinURLEscapesPlusAddresses() throws {
        let link = try XCTUnwrap(detect(notes: "https://meet.google.com/abc-defg-hij?hs=122"))
        let url = link.joinURL(googleAccount: "me+cal@gmail.com")
        XCTAssertEqual(authUser(in: url), "me+cal@gmail.com")
        XCTAssertTrue(url.absoluteString.contains("me%2Bcal@gmail.com"))
        XCTAssertTrue(url.absoluteString.contains("hs=122"))
    }

    func testJoinURLKeepsExistingAccountChoice() throws {
        let link = try XCTUnwrap(detect(notes: "https://meet.google.com/abc-defg-hij?authuser=1"))
        XCTAssertEqual(link.joinURL(googleAccount: "me@work.com"), link.url)
    }

    func testJoinURLIgnoresRenamedAccountsAndOtherProviders() throws {
        let meet = try XCTUnwrap(detect(notes: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(meet.joinURL(googleAccount: "Work"), meet.url)
        let zoom = try XCTUnwrap(detect(location: "https://zoom.us/j/1"))
        XCTAssertEqual(zoom.joinURL(googleAccount: "me@work.com"), zoom.url)
    }

    // MARK: - Real-world regression

    /// Verbatim Google Calendar invite boilerplate. It contains two decoy links
    /// after the join link — the tel.meet dial-in page and the support.google.com
    /// help article — either of which a naive "first URL" parser would pick.
    /// Verified against live Google Calendar data on 2026-08-02.
    func testRealGoogleInviteBoilerplate() {
        let link = detect(notes: """
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            Join with Google Meet: https://meet.google.com/xyz-abcd-efg
            Or dial: (US) +1 555-010-0199 PIN: 123456789#
            More phone numbers: https://tel.meet/xyz-abcd-efg?pin=7644906875876&hs=7

            Learn more about Meet at: https://support.google.com/a/users/answer/9282720

            Please do not edit this section.
            -::~:~::~:~:~:~:~:~:~:
            """)
        XCTAssertEqual(link?.provider, .googleMeet)
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/xyz-abcd-efg")
    }
}
