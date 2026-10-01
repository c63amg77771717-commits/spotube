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
    }
}
