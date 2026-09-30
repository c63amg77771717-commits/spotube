# EvanTube Google Drive playlist sync

Approved scope: iOS and existing Android app, EvanTube/MB3 playlists only. Provider-managed Spotube playlists are excluded. User supplied iOS OAuth client ID `239071444729-ltpo8bq50tkgqvilod56v5fcf65f38om.apps.googleusercontent.com` for bundle `com.c63amg77771717.evantube`.

## User experience

Library offers Google Drive sync, signed-in email, last successful sync, explicit sync/retry and disconnect. First connection (and account change) explicitly activates merging the current local library into the selected account. Local editing works offline. Active apps sync on launch/foreground and after local changes; no claim of guaranteed background iOS execution. Disconnect stops network activity and retains local playlists.

Use Google Sign-In SDK token storage/refresh. Request only `https://www.googleapis.com/auth/drive.appdata`. Never store access tokens in preferences or logs. iOS and Android OAuth clients must belong to the same Google Cloud project; Android must have its package/signing certificate registered. Actual Google login cannot be validated without user interaction.

## Shared wire format, version 1

Drive appDataFolder contains one journal per writer, name `evantube-playlists-v1-<writerId>.json`, MIME application/json. A writer ID is a secure device-local UUID scoped by the event deviceId (iOS Keychain ThisDeviceOnly, Android Keystore-backed storage); it is not copied by OS backups. Event deviceId remains stable in restored journals; duplicate ancestral events are harmless. Files are enumerated with spaces=appDataFolder, trashed=false and the filename prefix, paginated. A device only updates its own writer file. All matching files are read; duplicate event IDs are idempotent. Do not overwrite another device's file or remove history.

JSON object: `{ "schemaVersion": 1, "events": [...] }`.

Each event has required `id` (UUID string), `deviceId` (UUID string), `clock` (positive integer milliseconds <= 9007199254740991), `kind`, `playlistId` (string; empty only for orderPlaylists). Sort by ascending clock, then id using ASCII lexical order. New local clocks are max(current UTC milliseconds, largest observed clock + 1). UUIDs are lowercase. Duplicate event IDs with different payloads are invalid.

Kinds and additional fields:
- create: title (non-empty string).
- rename: title.
- delete: no additional fields. Permanent tombstone for this playlist ID, no later event resurrects it.
- putSong: song object `{youtubeId,title,artist,duration,thumbnailURL}`. youtubeId is 11 ASCII letters/digits/underscore/hyphen, title/artist strings, duration nonnegative integer seconds, thumbnailURL nullable string. Exclude temporary audio URLs.
- removeSong: songId.
- orderSongs: order array of song IDs. Listed existing songs first, unlisted existing songs retain their order.
- orderPlaylists: order array of playlist IDs; same stable ordering rule.

Replay creates playlists on create only, applies operations to existing non-deleted playlists, replaces song metadata without changing its position, and appends newly seen songs. Concurrent additions to different songs survive; last ordered operation wins for the same field/song. Delete wins for an entire playlist. Events referring to unknown/deleted playlists are harmless no-ops. Replaying all devices gives the same result. History, favorites, provider playlists and music files are outside this protocol.

Validation: max 5 MiB per journal, 20 MiB total download, 20,000 unique events total, 128 matching Drive files, title/artist <= 1,000 characters, IDs <= 128 ASCII characters, order arrays <= 20,000 items. Unknown schema/kinds/malformed payloads fail sync with an error; preserve local state and pending events. HTTP requests timeout, reject non-2xx and bound response size. Pagination is required. Mark last sync only after upload and local application succeed.

Per-device append-only journals avoid competing writes to a shared file. This is deliberately bounded for personal playlists; fail clearly at limits and migrate to compacted versioned snapshots before exceeding them.

## Integration

iOS: preserve existing LocalPlaylistRepository as UI/player source. Hook its single save path to record create/delete/rename/membership/order differences. Apply replayed cloud playlists through a bypass path so replay does not create fresh events. Store journal before applying local or remote mutations. Account switch resets sync metadata and seeds current local library only after explicit activation.

Android: add a separate EvanTube local playlist library using this journal and the existing MB3 parser. Keep metadata plugin playlist behavior intact. Expose import/create/edit/delete/reorder and playback where YouTube IDs can use the existing audio source path. Add Google Drive sync in this library. Persist mutation before reporting success; serialize sync/mutations so network await cannot overwrite newer local edits.

## Verification

Shared fixtures prove identical replay in Swift and Dart: duplicate events, independent offline additions, same-song removal, playlist deletion, ordering, invalid YouTube IDs and unknown schema. Tests assert mutations arriving during sync are retained. CI compiles native app, runs EvanTube tests and packages unsigned IPA. Android analysis/tests/build are attempted using available Flutter runtime/CI. Google account login, cross-device live sync, signing and CarPlay require device verification and must not be claimed passed.
