# EvanTube / Android Spotube Shared Online Playlist

EvanTube intentionally preserves Spotube 5.1.2's Metadata Plugin playlist backend and playlist CRUD implementation.

Compatibility contract:

- Same Metadata Plugin / provider account on Android and iOS.
- Provider playlist ID remains authoritative.
- Provider track IDs remain authoritative.
- Create/update/delete/add/remove are written through the Metadata Plugin API.
- The server/provider is the source of truth; local state is cache/UI state.
- EvanTube refreshes saved playlists every 45 seconds while open.
- An open playlist refreshes its track list every 45 seconds.
- Existing pull-to-refresh remains available.
- The original playlist CRUD provider files are not replaced or forked into a e the same Metadata Plugin account/provider.
