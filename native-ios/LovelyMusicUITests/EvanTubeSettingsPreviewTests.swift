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
        app.launchEnvironment["REVIEW_MODE"] = "1"
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for label in ["不允許", "Don't Allow", "Don’t Allow", "允許", "Allow"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        let demoSong = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'home_song_demo_'")
        ).firstMatch
        XCTAssertTrue(demoSong.waitForExistence(timeout: 30))
        demoSong.tap()
        let playPause = app.buttons["dock_play_pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 20))
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == '暫停'"), object: playPause
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        playPause.tap()
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
        let progress = app.descendants(matching: .any)["dock_progress_slider"].firstMatch
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(progress.isEnabled)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo:
                progress.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.5)))
        let seeked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = progress.value as? String,
                      let digits = value.split(whereSeparator: { !$0.isNumber }).first,
                      let percent = Int(digits) else { return false }
                return (52...68).contains(percent)
            }, object: progress
        )
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 10), .completed)
        XCTAssertEqual(playPause.label, "播放")
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
