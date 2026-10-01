import XCTest
@testable import LovelyMusic

final class FreeLyricsTests: XCTestCase {
    @MainActor func testLyricsDoNotRequireASubscription() {
        let manager = PremiumManager(featureFlagManager: FeatureFlagManager())
        manager.devPremiumOverride = false
        XCTAssertFalse(manager.isPremium)
        for feature in PremiumFeature.allCases {
            XCTAssertTrue(manager.canAccess(feature))
        }
        for _ in 0..<100 { XCTAssertTrue(manager.recordSkip()) }
        XCTAssertEqual(manager.remainingSkips, .max)
        XCTAssertTrue(manager.canDownload(currentCount: 100_000))
        XCTAssertEqual(manager.maxAllowedQuality(), "high")
    }

    @MainActor func testHighQualityDoesNotRequireASubscription() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PlaybackQualitySettings(defaults: defaults)
        settings.download = .high
        XCTAssertEqual(settings.effectiveDownloadQuality(isPremium: false), .high)
    }
}
