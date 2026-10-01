import Observation
import UIKit

/// Compatibility for existing playback/startup wiring. EvanTube has no advertising SDK.
@MainActor
@Observable
final class AdManager {
    let shouldShowAds = false
    let isInterstitialReady = false

    init(premiumManager: PremiumManager, featureFlagManager: FeatureFlagManager) {}

    func preloadInterstitial() async {}

    func recordSkipAndShowIfNeeded(from viewController: UIViewController? = nil) {}
}
