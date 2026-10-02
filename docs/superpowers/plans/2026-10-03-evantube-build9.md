# EvanTube build 9 and Android car UI preview

Approved scope: incorporate all recorded iOS fixes in build 9, and present Android car UI as static PNGs before changing its APK.

## iOS

1. Reproduce current defects on the existing macOS Actions workflow: playlist newest-first order and Drive replay; playback restore, explicit remote commands and recovery intent; feed parsing and recommendation refresh.
2. Capture actual assertion failures before applying production fixes. Keep the existing build and UI gates.
3. Fix at shared entry points using the current repositories, AudioEngine and existing search API. Do not add dependencies or replace architecture.
4. Add persistent successful-play history with deduplication and a read-only library entry. Keep history outside editable/Drive synced playlists.
5. Restore song, queue and progress paused; load a fresh source on explicit Play. Preserve user pause intent through recovery and interruptions. Enable persistence once for upgrades from the previous default-off setting, then preserve subsequent explicit choices.
6. Make chart playback use official online search; distinguish failed and empty recommendations and avoid caching empty results.
7. Review all owned diffs, rerun native/UI tests, inspect build 9 IPA metadata and screenshots, and publish separate build 9 installation notes. Actual intermittent YouTube service rejection still requires phone diagnostics.

Ownership: playback agent owns audio engine, persistence, recovery, remote/audio session managers and typed diagnostics; playlist agent owns playlist storage/order/history UI; recommendations agent owns home/feed/search resolution. Parent owns DI/app wiring, build version, CI, review and release artifacts.

## Android

Use the existing car project logo and night driving artwork. Show home, search, favorites, library, playlist, now playing, lyrics, profile, settings and Drive sync in one consistent charcoal/purple/blue/ice-cyan theme. Extend the artwork across the right content area while leaving the left navigation and bottom transport on dark backgrounds. Increase navigation and transport targets, keep the wordmark on one line, and reserve space for fixed transport controls. Render ten separate PNGs and publish a phone-viewable gallery. This preview uses labelled demonstration content; Android production code and APK wait for user review.

## Verification

- `git diff --check`
- `.github/workflows/evantube-native-ios-ipa.yml`: native unit tests, seven existing isolated simulator UI cases and a new playback-history UI case
- Existing `work/verify-build7-ipa.py` with build number 9
- Android: bundled Playwright with installed Edge, layout overflow checks and visual inspection of rendered PNGs
