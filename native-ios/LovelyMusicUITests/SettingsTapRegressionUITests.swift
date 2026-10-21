import XCTest

/// Build34: tapping the empty/right-hand side of Settings cards must work.
/// No live Google login, YouTube sign-in, file import, or Drive writes occur.
final class SettingsTapRegressionUITests: XCTestCase {
    @MainActor func testThreeSettingsEntrypointsAreTappableFromCardRightSide() {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { [weak self] in
            await MainActor.run {
                guard let self, (self.testRun?.totalFailureCount ?? 0) > 0 else { return }
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Settings navigation failure"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Settings navigation failure hierarchy"
                hierarchy.lifetime = .keepAlways
                self.add(hierarchy)
            }
        }
        app.launchArguments = [
            "-hasCompletedOnboarding", "-appLanguage", "zh-Hant",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-evantubeSettingsPreview", "-evantubeSignedInSettingsPreview",
        ]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for label in ["不允許", "Don't Allow", "Don’t Allow", "允許", "Allow"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        app.launch()

        let library = app.buttons["tab_library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let gear = app.buttons["library_settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()

        // Tapping the card's empty side opens a real account page, not logout.
        let account = app.buttons["settings_youtube_account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        XCTAssertTrue(account.isHittable)
        tapRightSide(account)
        let accountPage = app.navigationBars["YouTube 帳號"].firstMatch
        XCTAssertTrue(accountPage.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["account_reauthenticate"].exists)
        app.buttons["account_details_done"].tap()

        let importer = app.buttons["settings_playlist_import"].firstMatch
        XCTAssertTrue(accountPage.waitForNonExistence(timeout: 10),
                      "Account sheet must close before tapping the import card")
        XCTAssertTrue(account.exists)
        XCTAssertTrue(importer.exists)
        XCTAssertTrue(importer.isHittable)
        tapRightSide(importer)
        let importPage = app.navigationBars["匯入歌單"].firstMatch
        XCTAssertTrue(importPage.waitForExistence(timeout: 12),
                      "Import ZIP sheet must open from the full card")
        XCTAssertTrue(app.buttons["選取歌單 ZIP"].exists)
        app.buttons["完成"].firstMatch.tap()

        let drive = app.buttons["settings_drive_sync"].firstMatch
        XCTAssertTrue(importPage.waitForNonExistence(timeout: 12),
                      "Import sheet must close before tapping the Drive card")
        XCTAssertTrue(drive.exists)
        XCTAssertTrue(drive.isHittable)
        tapRightSide(drive)
        XCTAssertTrue(app.navigationBars["Google Drive 同步"].waitForExistence(timeout: 12),
                      "Drive sync sheet must open from the full card")
        XCTAssertTrue(app.staticTexts["跨裝置歌單"].exists)
        app.buttons["完成"].firstMatch.tap()
    }

    @MainActor private func tapRightSide(_ card: XCUIElement) {
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5)).tap()
    }
}
