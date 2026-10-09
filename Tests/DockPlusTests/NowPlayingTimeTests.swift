import XCTest
@testable import DockPlus

/// The Now Playing consent decision, the artwork status check and the locale-aware time templates.
final class NowPlayingTimeTests: XCTestCase {
    // MARK: - Consent

    func testNeverAskedPlayerIsOfferedEvenWhileAnotherShows() {
        let state = WidgetsModel.consentState(shown: true, denied: nil, unasked: "Music")
        XCTAssertNil(state.denied)
        XCTAssertFalse(state.needsConsent)
    }

    func testNeverAskedOutranksRefusedWhenNothingShows() {
        let state = WidgetsModel.consentState(shown: false, denied: "Spotify", unasked: "Music")
        XCTAssertEqual(state.denied, "Music")
        XCTAssertTrue(state.needsConsent)
    }

    func testRefusedOnlySendsToSettings() {
        let state = WidgetsModel.consentState(shown: false, denied: "Spotify", unasked: nil)
        XCTAssertEqual(state.denied, "Spotify")
        XCTAssertFalse(state.needsConsent)
    }

    func testNothingWrongWhenNothingIsDenied() {
        let state = WidgetsModel.consentState(shown: false, denied: nil, unasked: nil)
        XCTAssertNil(state.denied)
        XCTAssertFalse(state.needsConsent)
    }

    // MARK: - Tap

    func testTapAsksWhileANeverAskedPlayerExistsAndNothingPlays() {
        // Spotify paused and shown, Music never asked: a click must not resume the wrong player.
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: true, isPlaying: false, denied: nil, unasked: "Music"), .allow)
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: false, isPlaying: false, denied: "Music", unasked: "Music"), .allow)
    }

    func testTapPlaysPausesWhileSomethingPlaysOrOnceAnswered() {
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: true, isPlaying: true, denied: nil, unasked: "Music"), .playPause)
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: true, isPlaying: false, denied: nil, unasked: nil), .playPause)
    }

    func testTapOpensSettingsOnlyForARefusedPlayerWithNothingShown() {
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: false, isPlaying: false, denied: "Spotify", unasked: nil), .openSettings)
        XCTAssertEqual(
            WidgetsModel.tapAction(showing: true, isPlaying: false, denied: "Spotify", unasked: nil), .playPause)
    }

    // MARK: - Artwork status

    func testOnlyA2xxHTTPResponseIsASuccess() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))
        func response(_ code: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        XCTAssertTrue(WidgetsModel.isSuccess(response(200)))
        XCTAssertFalse(WidgetsModel.isSuccess(response(302)))
        XCTAssertFalse(WidgetsModel.isSuccess(response(404)))
        XCTAssertFalse(WidgetsModel.isSuccess(response(503)))
        XCTAssertFalse(WidgetsModel.isSuccess(URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    }

    // MARK: - Time templates

    private let sample = Date(timeIntervalSince1970: 1_791_450_000)  // 2026-10-08 09:00 UTC

    private func format(_ template: String, _ id: String) -> String {
        let formatter = DateFormatter.localized(template, locale: Locale(identifier: id))
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: sample)
    }

    func testTwentyFourHourSwitchForcesTheHourCycle() {
        XCTAssertEqual(format("Hmm", "en_US"), "09:00")
        XCTAssertEqual(format("Hmm", "de_DE"), "09:00")
        XCTAssertTrue(format("hmma", "en_US").contains("AM"))
        XCTAssertFalse(format("hmma", "en_US").hasPrefix("09"))
    }

    func testDateFieldsFollowTheLocaleOrder() {
        XCTAssertTrue(format("EEEMMMd", "en_US").hasPrefix("Thu"))
        XCTAssertNotEqual(format("EEEMMMd", "en_US"), format("EEEMMMd", "de_DE"))
        XCTAssertTrue(format("EEEMMMd", "de_DE").contains("Okt"))
    }

    func testLocaleDecidesTheFirstRunClockHours() {
        XCTAssertTrue(DockSettings.localeUses24Hour(Locale(identifier: "de_DE")))
        XCTAssertTrue(DockSettings.localeUses24Hour(Locale(identifier: "fr_FR")))
        XCTAssertFalse(DockSettings.localeUses24Hour(Locale(identifier: "en_US")))
    }
}
