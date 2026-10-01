import XCTest
@testable import LovelyMusic

final class PlaybackErrorTests: XCTestCase {
    func testUnavailableStreamDoesNotImplyRegionOrLogin() {
        for message in ["No audio stream available", "Video unavailable: Unknown", "沒有可用的音訊串流"] {
            XCTAssertEqual(PlaybackErrorCategory.classify(message), .unknown)
        }
        XCTAssertEqual(PlaybackErrorCategory.classify("Video unavailable: This video is not available in your country"), .regionBlocked)
        XCTAssertEqual(PlaybackErrorCategory.classify("Video unavailable: This video has been removed"), .songRemoved)
        XCTAssertEqual(PlaybackErrorCategory.classify("Sign in to confirm you're not a bot"), .authRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("請登入 YouTube"), .authRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("無法在你的地區播放"), .regionBlocked)
        XCTAssertEqual(PlaybackErrorCategory.classify("這首歌已從音源移除"), .songRemoved)
        XCTAssertEqual(PlaybackErrorCategory.classify("Network error: TLS authentication failed"), .noInternet)
    }

    @MainActor func testExpiredOrVisitorCookiesDoNotMeanSignedIn() {
        let now = Date()
        func cookie(_ name: String, expires: Date) -> HTTPCookie {
            HTTPCookie(properties: [
                .name: name, .value: "test-only", .domain: ".youtube.com",
                .path: "/", .expires: expires,
            ])!
        }
        let future = now.addingTimeInterval(600)
        let past = now.addingTimeInterval(-600)
        XCTAssertFalse(YouTubeAuthManager.hasActiveAuthCookies([cookie("VISITOR_INFO1_LIVE", expires: future)], at: now))
        XCTAssertFalse(YouTubeAuthManager.hasActiveAuthCookies([cookie("SAPISID", expires: past), cookie("SID", expires: future)], at: now))
        XCTAssertTrue(YouTubeAuthManager.hasActiveAuthCookies([cookie("SAPISID", expires: future), cookie("SID", expires: future)], at: now))
    }
}
