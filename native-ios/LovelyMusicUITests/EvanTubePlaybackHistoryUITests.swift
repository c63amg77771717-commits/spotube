import XCTest

final class EvanTubePlaybackHistoryUITests: XCTestCase {
    @MainActor func testLibraryOpensReadOnlyPlaybackHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "-appLanguage", "zh-Hant",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        app.launch()

        let library = app.buttons["tab_library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let history = app.buttons["library_playback_history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        for _ in 0..<3 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable)
        history.tap()

        let options = app.buttons["歌單選項"]
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '播放紀錄'")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "播放紀錄歌單"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        options.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "label == 'Rename' OR label == '重新命名' OR label == '重命名'"
        )).count, 0)
    }
}
