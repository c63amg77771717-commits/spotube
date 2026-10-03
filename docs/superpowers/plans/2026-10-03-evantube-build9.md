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

## Post-delivery playback incident

The user's 2026-10-03 build 9 device trace confirms playback verification rejection after a successful track was paused. A fresh watch-session bootstrap with authentication material is also rejected; two configured fallback clients are unavailable because playback-source configuration is absent. See [the evidence and pending verification](../../diagnostics/2026-10-03-build9-playback-verification.md). Treat this as unresolved for the next iOS build; do not mark it fixed without affected-device recovery evidence.

Follow-up: the user confirms the app's YouTube watch-page playback works. Native tests reproduced and repaired browser-cookie handoff, retry progress loss, stale delayed retries, and premature raw fMP4 deferred-seek consumption. Final source review passed; all 115 simulator tests passed in run `37095517704`, with no uploaded artifacts. These app defects are not a confirmed explanation for the remote verification trigger; affected-phone validation remains pending.

The source-only phase used the dedicated `codex/ios-playback-session-tests-20261003` branch and `.github/workflows/evantube-native-ios-tests.yml`, without producing IPA/APK files.

Latest user direction: also produce the repaired iOS IPA. Set both app and notification extension to build 10, use the normal iOS branch and packaging workflow, require all native and eight isolated UI checks, then verify and deliver the unsigned device IPA. Keep native tests serial as in the verified source-only workflow because authentication tests share Keychain state. Android car assessment remains read-only and does not produce an APK. Native YouTube service acceptance remains an affected-device check.

Build 10 delivery: run `37096713345` at `bcac3e70` succeeded with 115 native tests and eight UI cases. The local IPA passed CRC, arm64, both build-number and embedded configuration checks. UI screenshots from the same run were checked. The user subsequently requested a simultaneous Android car repair and APK; that independent work uses the existing local build46 project and delivers build47 to Android's local outputs folder. Both installation packages must reside locally; the user does not need to download from GitHub.
