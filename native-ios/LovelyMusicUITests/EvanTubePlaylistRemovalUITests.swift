import XCTest

final class EvanTubePlaylistRemovalUITests: XCTestCase {
    @MainActor func testSingleSongRemovalCancelAndPersistenceAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "-appLanguage", "zh-Hant",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-evantubePlaylistRemovalPreview", "-evantubeResetPlaylistRemovalPreview"]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for label in ["不允許", "Don't Allow", "Don’t Allow", "允許", "Allow"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        openFixture(app)
        let row = app.buttons["playlist_song_row_demo_song_removal_test"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        openRemoval(app)
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(row.exists, "Cancelling confirmation preserves the song")

        openRemoval(app)
        let confirm = app.buttons["移除歌曲"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["無法移除歌曲"].exists)
        save(app, "單首歌曲已移除")

        app.terminate()
        // Reset only on the first launch; relaunch reads the persisted removal.
        app.launchArguments.removeAll { $0 == "-evantubeResetPlaylistRemovalPreview" }
        app.launch()
        openFixture(app)
        XCTAssertTrue(app.buttons["playlist_detail_options"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["playlist_song_row_demo_song_removal_test"].exists)
        save(app, "重新啟動後移除仍保留")
    }

    @MainActor private func openFixture(_ app: XCUIApplication) {
        let library = app.buttons["tab_library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let playlist = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'library_playlist_' AND label CONTAINS '刪歌測試歌單'"
        )).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 15))
        for _ in 0..<5 where !playlist.isHittable { app.swipeUp() }
        XCTAssertTrue(playlist.isHittable)
        playlist.tap()
    }

    @MainActor private func openRemoval(_ app: XCUIApplication) {
        let menu = app.buttons["playlist_song_menu_demo_song_removal_test"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        for _ in 0..<3 where !menu.isHittable { app.swipeUp() }
        // Nested SwiftUI Menu controls expose a valid frame but AX tap can attempt
        // an unsupported scroll-to-visible; use the visible frame as other UI flows do.
        let frame = menu.frame
        XCTAssertTrue(app.frame.contains(frame))
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let remove = app.buttons["從此歌單移除"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
    }

    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
