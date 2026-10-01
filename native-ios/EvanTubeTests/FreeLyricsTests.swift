import XCTest
@testable import LovelyMusic

final class FreeLyricsTests: XCTestCase {
    @MainActor func testLyricsDoNotRequireASubscription() {
        let manager = PremiumManager()
        manager.devPremiumOverride = false
        XCTAssertFalse(manager.isPremium)
        XCTAssertTrue(manager.canAccess(.syncedLyrics))
        XCTAssertFalse(manager.canAccess(.equalizer))
    }
}
