import XCTest

@MainActor
final class EvanTubeLyricsCandidateUITests: XCTestCase {
    func testCandidateOnlyResultReachesFullPlayerAndAllowsPlainLyricsSelection() {
        continueAfterFailure = false
        let app = launch(resetSelection: true)
        defer { app.terminate() }
        openFullPlayer(app)
        let picker = app.buttons["lyrics_version_picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Repository candidates must reach the actual full-player selector")
        XCTAssertTrue(app.staticTexts["lyrics_candidate_prompt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["找不到這首歌的相符歌詞"].firstMatch.exists)
        savePickerEvidence(app)
        XCTAssertTrue(picker.isHittable, "Candidate menu must be reachable without synthetic scroll actions")
        picker.tap()
        chooseSecond(app)
        XCTAssertTrue(app.staticTexts["Candidate UI second recording"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["lyrics_plain_notice"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["lyrics_candidate_prompt"].firstMatch.exists)
    }

    func testSelectedRecordingIsRememberedAcrossActualAppRelaunch() {
        continueAfterFailure = false
        let app = launch(resetSelection: true)
        openFullPlayer(app)
        let picker = app.buttons["lyrics_version_picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        savePickerEvidence(app)
        XCTAssertTrue(picker.isHittable, "Candidate menu must be reachable without synthetic scroll actions")
        picker.tap()
        chooseSecond(app)
        XCTAssertTrue(app.staticTexts["Candidate UI second recording"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_RESET"] = "0"
        app.launch()
        defer { app.terminate() }
        openFullPlayer(app)
        XCTAssertTrue(app.staticTexts["Candidate UI second recording"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["lyrics_candidate_prompt"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["lyrics_plain_notice"].firstMatch.exists)
    }

    private func savePickerEvidence(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "lyrics-candidate-menu-touch-target"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(resetSelection: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "-appLanguage", "en",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-playerLyricsVisible", "YES", "-evantubeSettingsPreview"]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_FIXTURE"] = "1"
        app.launchEnvironment["EVANTUBE_LYRICS_CANDIDATE_RESET"] = resetSelection ? "1" : "0"
        addUIInterruptionMonitor(withDescription: "Preview permissions") { alert in
            for label in ["Don't Allow", "Don’t Allow", "不允許"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        return app
    }

    private func openFullPlayer(_ app: XCUIApplication) {
        let mini = app.descendants(matching: .any)["dock_mini_player"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
    }

    private func chooseSecond(_ app: XCUIApplication) {
        let second = app.buttons.matching(NSPredicate(format:
            "identifier == %@ OR label CONTAINS %@", "lyrics_candidate_102", "6:00")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
    }
}
