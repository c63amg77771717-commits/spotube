# Google Drive playlist sync implementation plan

Goal: implement the approved iOS/Android EvanTube-only playlist sync and rebuild the iOS test IPA.

Spec: ../specs/2026-10-01-google-drive-sync.md

Architecture: Google Sign-In plus Drive REST appDataFolder; bounded append-only device journals with deterministic replay. iOS uses its current repository; Android gets a local EvanTube library separate from metadata plugins.

- [x] Shared contract: add fixture and replay/validation checks in both languages.
- [x] iOS: journal store, repository diff recording, Google Sign-In/Drive transport, sync UI, URL callback and user Client ID.
- [x] Android: matching journal and Drive transport, local EvanTube library/import/UI, foreground/manual sync.
- [x] Review: account changes, local edits during network waits, pagination, malformed remote data, offline retry and deletion semantics.
- [x] Verify: targeted tests, platform compilation, native IPA CI, artifact integrity; deliver with exact remaining Google Cloud/device prerequisites.

Independent platform changes are delegated under the dispatching-parallel-agents skill. Root owns spec, fixtures, native-ios and native CI; Android agent owns Dart/Flutter/Android files only. No agent commits or pushes shared changes until root review.

Verification: native build and 17 tests passed in GitHub Actions run 36789873504; IPA ZIP integrity, bundle identity, OAuth callback and Client ID checked. Android 16 targeted tests, focused analyzer and APK build passed in run 36792263250 (commit 4545274d). APK signed locally with the existing stable test key, verified with apksigner and zipalign; manifest confirms oss.krtirtho.spotube.dev, version 5.1.2-dev (45), min SDK 24. Both final archives passed ZIP integrity checks. Installation and Google Cloud configuration instructions are included beside the output files. Real Google authorization, two-device sync, full playback and CarPlay require device testing and are not claimed verified.

Deliverables in the parent task outputs directory:
- EvanTube-iOS-GoogleDrive-unsigned.ipa — SHA-256 C162CBA7F67B034D5FA1C830C7CB0979E10EBCA5FE9FE64F8DEEC2719811D6FC
- EvanTube-Android-GoogleDrive-test.apk — SHA-256 67039778FAB1668623E998A60825E08B0E29D1E6D70C1958FC97EE9A698E3468

Android OAuth test registration uses package oss.krtirtho.spotube.dev and certificate SHA-1 C4:FA:9D:F5:9B:D6:1F:D9:04:3F:38:1E:E3:C3:54:12:97:75:C0:F9, in the same Google Cloud project as the iOS client. Signing keys are local only, never committed or uploaded to CI.
