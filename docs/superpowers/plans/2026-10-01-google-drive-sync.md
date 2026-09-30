# Google Drive playlist sync implementation plan

Goal: implement the approved iOS/Android EvanTube-only playlist sync and rebuild the iOS test IPA.

Spec: ../specs/2026-10-01-google-drive-sync.md

Architecture: Google Sign-In plus Drive REST appDataFolder; bounded append-only device journals with deterministic replay. iOS uses its current repository; Android gets a local EvanTube library separate from metadata plugins.

- [ ] Shared contract: add fixture and replay/validation checks in both languages.
- [ ] iOS: journal store, repository diff recording, Google Sign-In/Drive transport, sync UI, URL callback and user Client ID.
- [ ] Android: matching journal and Drive transport, local EvanTube library/import/UI, foreground/manual sync.
- [ ] Review: account changes, local edits during network waits, pagination, malformed remote data, offline retry and deletion semantics.
- [ ] Verify: targeted tests, platform compilation, native IPA CI, artifact integrity; deliver with exact remaining Google Cloud/device prerequisites.

Independent platform changes are delegated under the dispatching-parallel-agents skill. Root owns spec, fixtures, native-ios and native CI; Android agent owns Dart/Flutter/Android files only. No agent commits or pushes shared changes until root review.
