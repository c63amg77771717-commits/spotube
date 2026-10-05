import XCTest

@MainActor
final class EvanTubeLrcApiSecondaryUITests: XCTestCase {
    func testCrossProviderSelectionAndAttributionSurviveActualRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "-appLanguage", "en", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US", "-playerLyricsVisible", "YES", "-evantubeSettingsPreview"]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        app.launchEnvironment["EVANTUBE_LRCAPI_FIXTURE"] = "1"
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_RESET"] = "1"
        app.launch()
        openFullPlayer(app)
        XCTAssertTrue(app.buttons["lyrics_version_picker"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cross-provider-candidate-menu-touch-target"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(app.buttons["lyrics_version_picker"].isHittable)
        app.buttons["lyrics_version_picker"].tap()
        let choice = app.buttons["lyrics_candidate_lrcapi_101"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(app.staticTexts["LrcApi UI first recording"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["lyrics_provider_attribution"].label, "LrcApi")
        XCTAssertFalse(app.staticTexts["lyrics_plain_notice"].exists)
        app.terminate()
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_RESET"] = "0"
        app.launch()
        defer { app.terminate() }
        openFullPlayer(app)
        XCTAssertTrue(app.staticTexts["LrcApi UI first recording"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["lyrics_provider_attribution"].label, "LrcApi")
    }
    private func openFullPlayer(_ app: XCUIApplication) {
        let mini = app.descendants(matching: .any)["dock_mini_player"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
    }
}
