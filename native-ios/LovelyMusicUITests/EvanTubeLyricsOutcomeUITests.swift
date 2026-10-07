import XCTest

@MainActor
final class EvanTubeLyricsOutcomeUITests: XCTestCase {
    func testSecondaryRejectedResponseIsNotMaskedByPrimary503() {
        check("rejected", message: "Returned lyrics did not match this song", partialFailure: true)
    }
    func testSecondaryEmptyResponseIsNotMaskedByPrimary503() {
        check("empty", message: "Lyrics sources returned no results", partialFailure: true)
    }
    func testBothUnavailableSourcesReachTheRetryUI() {
        check("unavailable", message: "Lyrics source temporarily unavailable", partialFailure: false)
    }
    private func check(_ mode: String, message: String, partialFailure: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "-appLanguage", "en", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-playerLyricsVisible", "YES", "-evantubeSettingsPreview"]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        app.launchEnvironment["EVANTUBE_LRCAPI_FIXTURE"] = "1"
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_RESET"] = "1"
        app.launchEnvironment["EVANTUBE_LYRICS_OUTCOME_FIXTURE"] = mode
        app.launch(); defer { app.terminate() }
        let mini = app.descendants(matching: .any)["dock_mini_player"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let outcome = app.staticTexts["lyrics_lookup_outcome"].firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 15))
        XCTAssertEqual(outcome.label, message)
        XCTAssertEqual(app.staticTexts["lyrics_partial_source_failure"].firstMatch.exists, partialFailure)
        XCTAssertFalse(app.buttons["lyrics_version_picker"].firstMatch.exists)
        let retry = app.buttons["lyrics_retry"].firstMatch
        XCTAssertTrue(retry.exists); XCTAssertTrue(retry.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "lyrics-outcome-" + mode; attachment.lifetime = .keepAlways; add(attachment)
    }
}
