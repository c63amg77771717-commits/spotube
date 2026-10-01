import XCTest

final class EvanTubeSettingsPreviewTests: XCTestCase {
    @MainActor func testLibraryGearAndSettingsPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "-appLanguage", "zh-Hant",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-disableScreenshots", "NO",
        ]
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for label in ["不允許", "Don't Allow", "Don’t Allow", "允許", "Allow"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        let library = app.buttons["tab_library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let gear = app.buttons["library_settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["為你而來"].exists)
        save(app, name: "01-為你而來-設定齒輪")

        gear.tap()
        let playlistImport = app.buttons["settings_playlist_import"]
        XCTAssertTrue(playlistImport.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["settings_drive_sync"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format:
            "label CONTAINS '升級' OR label CONTAINS '訂閱' OR label CONTAINS 'Premium'"
        )).count, 0)
        save(app, name: "02-設定-歌單與同步")
        app.swipeUp()
        app.swipeUp()
        save(app, name: "03-設定-音訊語言隱私")
    }

    @MainActor private func save(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
