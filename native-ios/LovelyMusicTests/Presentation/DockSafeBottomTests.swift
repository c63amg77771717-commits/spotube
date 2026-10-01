import SwiftUI
import XCTest

@testable import LovelyMusic

/// Tests covering `.dockSafeBottom()` and EvanTube's disabled advertising compatibility.
@MainActor
final class DockSafeBottomTests: XCTestCase {

    // MARK: - polish-A2 / A3 — DockSafeBottom modifier

    /// The modifier must compose cleanly onto a SwiftUI `ScrollView` without
    /// crashing during view-tree construction.
    func test_dockSafeBottom_appliedToScrollView_doesNotCrash() {
        let view = ScrollView {
            VStack {
                ForEach(0..<10, id: \.self) { Text("Row \($0)") }
            }
        }
        .dockSafeBottom()

        // Construct the underlying body. If the modifier produces an invalid
        // tree the call below traps; reaching the assertion proves the tree
        // was built successfully.
        _ = UIHostingController(rootView: view)
        XCTAssertNotNil(view)
    }

    func test_adManager_staysDisabledWhenRemoteConfigEnablesAds() async throws {
        let suiteName = "no_ads_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let flags = FeatureFlagManager(apiKey: nil, defaults: defaults)
        let payload = try JSONSerialization.data(withJSONObject: [
            "config_json": #"{"monetization":{"ads_enabled":true}}"#
        ])
        XCTAssertTrue(flags.applyRemoteConfigData(payload))
        XCTAssertTrue(flags.isAdsEnabled)
        let premium = PremiumManager(featureFlagManager: flags)
        let adManager = AdManager(
            premiumManager: premium,
            featureFlagManager: flags
        )

        XCTAssertFalse(adManager.shouldShowAds)
        await adManager.preloadInterstitial()
        adManager.recordSkipAndShowIfNeeded()
        XCTAssertFalse(adManager.isInterstitialReady)
        XCTAssertFalse(adManager.shouldShowAds)
    }
}
