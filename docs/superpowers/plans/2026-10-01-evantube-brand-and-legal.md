# EvanTube approved brand and legal implementation

**Goal:** Ship the user's approved loading, About, privacy and terms pages in a new unsigned iOS IPA. More Than Music matches Evan's white text.

**Architecture:** Reuse SwiftUI Theme and dock clearance, native NavigationLink document readers, and an iOS launch storyboard. Legal copy comes from the approved 2026-10-01 review draft. Online configuration refresh runs in the background; no artificial launch delay. Remove the Google advertising SDK before publishing the no-ad-tracking policy.

**Technology:** SwiftUI, UIKit launch storyboard, XcodeGen, existing XCTest and GitHub macOS CI.

1. Replace AboutView's original developer links and footer; show Evan Liao, c63amg77771717@gmail.com, live bundle version, approved logo and copyright. Keep upstream and bundled-music credits separately.
2. Add native privacy and terms readers with approved copy, 2026-10-01 effective date and third-party reference links. Point every settings/legal entry to these views; retain dock clearance.
3. Remove GoogleMobileAds package, metadata, runtime startup and ad placements. Check with native-ios/scripts/check_no_ads.py.
4. Replace the static OS launch screen with the approved mark, white Evan/tagline, gradient Tube, creator and copyright. Remove remote CMS startup gating and the timed splash; provide a DEBUG-only launch preview route.
5. Capture real native loading, About and legal page screenshots. Test navigation, creator/contact identity, no draft marker and content clearance. Retain existing playlist/sync/settings regressions.
6. Review the integrated diff, bump build to 5, commit only authorized changes and run macOS CI. Resolve any failures, download and inspect the IPA plus screenshots, and deliver the verified files.

No Android work. Do not stage the unrelated 2026-09-30 plan/spec edits. Unsigned installation still requires the user's own signing; online-source credentials and physical-device playback are separate validation limits.
