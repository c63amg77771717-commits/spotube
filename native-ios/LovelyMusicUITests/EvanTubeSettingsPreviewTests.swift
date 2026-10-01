import XCTest

final class EvanTubeSettingsPreviewTests: XCTestCase {
    @MainActor func testLibraryGearAndSettingsPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "-appLanguage", "zh-Hant",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-disableScreenshots", "NO",
            "-evantubeSettingsPreview",
        ]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for label in ["不允許", "Don't Allow", "Don’t Allow", "允許", "Allow"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        save(app, name: "00-預覽啟動狀態")
        let playPause = app.buttons["dock_play_pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 30))
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
        XCTAssertTrue(app.navigationBars["媒體庫"].exists)
        save(app, name: "01-媒體庫-設定齒輪")

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
                guard let value = progress.value as? String else { return false }
                let times = value.components(separatedBy: "／").compactMap { label -> Double? in
                    let parts = label.split(separator: ":").compactMap { Double($0) }
                    guard parts.count == 2 else { return nil }
                    return parts[0] * 60 + parts[1]
                }
                guard times.count == 2, times[1] > 0 else { return false }
                return (0.52...0.68).contains(times[0] / times[1])
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
        let footer = app.descendants(matching: .any)["settings_footer_terms"].firstMatch
        let dock = app.descendants(matching: .any)["floating_dock"].firstMatch
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(dock.exists)
        XCTAssertLessThan(footer.frame.maxY, dock.frame.minY - 8)
        save(app, name: "03-設定-音訊語言隱私")

        footer.tap()
        XCTAssertTrue(app.navigationBars["使用條款"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS 'Evan Liao' AND label CONTAINS '生效日期'"
        )).firstMatch.exists)
        save(app, name: "06-使用條款")
        verifyDocumentFooter(app, above: dock)
        app.buttons["legal_back"].tap()

        let about = app.buttons["settings_about"]
        for _ in 0..<4 where !about.isHittable { app.swipeDown() }
        XCTAssertTrue(about.isHittable)
        about.tap()
        XCTAssertTrue(app.navigationBars["關於 EvanTube"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["about_creator"].exists)
        XCTAssertEqual(app.staticTexts["about_creator"].label, "Evan Liao")
        XCTAssertTrue(app.descendants(matching: .any)["about_contact"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Made with ❤️ by iletai"].exists)
        XCTAssertFalse(app.staticTexts["審核草案"].exists)
        save(app, name: "04-關於EvanTube")
        verifyDocumentFooter(app, above: dock, footerIdentifier: "about_footer")
        save(app, name: "04-關於EvanTube-製作者與條款")

        let privacy = app.buttons["about_privacy"]
        for _ in 0..<4 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacy.isHittable)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["隱私權政策"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS 'c63amg77771717@gmail.com' AND label CONTAINS '生效日期'"
        )).firstMatch.exists)
        save(app, name: "05-隱私權政策")
        verifyDocumentFooter(app, above: dock)
    }

    @MainActor func testLaunchBrandingPreview() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-evantubeLaunchPreview", "-disableScreenshots", "NO",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["More Than Music"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Evan Liao"].exists)
        XCTAssertTrue(app.staticTexts["© 2026 Evan Liao · EvanTube"].exists)
        XCTAssertFalse(app.staticTexts["審核草案"].exists)
        save(app, name: "00-新版載入畫面")
    }

    @MainActor private func verifyDocumentFooter(
        _ app: XCUIApplication, above dock: XCUIElement, footerIdentifier: String = "legal_footer"
    ) {
        let footer = app.staticTexts[footerIdentifier]
        for _ in 0..<12 {
            if footer.isHittable && footer.frame.maxY < dock.frame.minY - 8 { break }
            app.swipeUp()
        }
        XCTAssertTrue(footer.isHittable)
        XCTAssertLessThan(footer.frame.maxY, dock.frame.minY - 8)
    }

    @MainActor private func save(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
