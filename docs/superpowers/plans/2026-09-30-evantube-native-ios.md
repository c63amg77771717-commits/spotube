# EvanTube native iOS IPA plan

The user's 2026-09-30 direction supersedes the Flutter-only packaging architecture: use LovelyMusic for native playback and CarPlay, adapt Beans-style local playlists and library operations to LovelyMusic's single player and String song IDs, then carry forward the approved EvanTube UI, MB3 import and live homepage.

1. Import LovelyMusic's Apache-2.0 source into `native-ios/`, retain upstream notices, and verify a clean unsigned device build on macOS CI. Rebrand the app identifier, display name and selected icon without disrupting CarPlay scene or remote controls.
2. Adapt the local library repository to support playlist and song reordering and a clear add/remove flow. Keep one playlist repository and one playback queue; use LovelyMusic song IDs for native playback. Preserve source IDs separately in import reports.
3. Implement MB3 ZIP selection and parsing with the existing known export fixture, bounded decompression, user review before save, deduplication and truthful skip/error counts. Only directly playable YouTube IDs become `Song` records. Other rows require a verified lookup or stay skipped.
4. Build the six approved home sections with actual history, LovelyMusic recommendations and timed public chart/release feeds. Label regional charts by language and region, and resolve public-feed tracks to native songs before playing. Never show example rows as online data.
5. Apply the approved Neo Noir palette and selected artwork to home, navigation, mini-player and full player; ensure one fixed-position play/pause control reflects the actual player state.
6. Build unsigned IPA from the isolated feature branch in GitHub Actions, inspect Payload/app identity/icon and save the artifact under `outputs/`. Installation and CarPlay on a personal device require appropriate signing and CarPlay entitlement for the new app ID; do not claim those from an unsigned build.

Do not modify the user's Android checkout or merge into master. Validate each feature with focused tests or build diagnostics. Record the exact commit used for the delivered IPA.
