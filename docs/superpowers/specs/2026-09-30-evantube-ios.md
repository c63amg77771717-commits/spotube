# EvanTube iOS approved implementation

## User decisions

Implement the approved EvanTube iOS redesign and MB3 playlist import. Work may modify source and run tests. Do not build, export, upload, or publish an IPA or other installation package yet. The user will design the desktop icon; leave app icon assets unchanged until that design arrives. Do not modify the user's existing Android checkout or its uncommitted work.

The approved UI source is C:/Users/Admin/.codex/visualizations/2026/09/30/01a0f145-c9dc-7e20-8427-457c24c6692e/evantube-dark-preview.html. Static screenshots are in outputs/evantube-home-accent-final.jpg and outputs/evantube-now-playing.jpg. These are design references, not application data or code requirements.

## Appearance

Use a midnight charcoal/navy background (#080d15), opaque cards (#111b28), primary text (#edf3ff), secondary text (#a4afc1). The approved accent is horizontal purple to blue to ice cyan: #c174ff at 0%, #ac70ff at 50%, #729eff at 82%, #84dfff at 100%. Purple must remain clearly visible.

Apply the gradient to Tube in EvanTube, MORE THAN MUSIC, home search icon, recent playback history icon, bottom navigation icons AND labels (Home/Search/Library), playback progress and play/pause ring, and accent button borders. Active navigation gets a restrained purple glow. The home section link 媒體庫 beside 最近播放 uses the same secondary gray as 為你而來. Use Traditional Chinese copy matching the reference. Keep actual artwork, song title, artist, timing, and playback actions connected to existing playback state; never hardcode the demonstration song.

## Homepage data and actions

Provide all six sections: 最近播放, 推薦音樂, 最近熱門, 各語系音樂排行, 本週精選, 最新發行. Reuse the app's history, metadata plugin recommendations, and player. Show truthful loading, empty, auth-required, error, and retry states. Do not display FakeData as real content on empty/error. Pull-to-refresh must invalidate/refetch relevant requests.

Recent playback reads the existing history database. Personalized recommendations use the logged-in metadata plugin's browse sections and existing real recommendations. Weekly choices use the logged-in weekly recommendation playlist when available, otherwise explicitly label selections from the ListenBrainz community weekly chart with the actual period. Latest releases use real recent-release metadata (public fallback where no account is connected), exclude future releases, and show actual dates.

Regional charts are language plus REGION, e.g. 華語／台灣, 粵語／香港, 日語／日本; state that regional charts can contain other languages. Cover available language/region choices accurately without claiming to identify lyric language. The Apple chart endpoint verified successfully is https://rss.marketingtools.apple.com/api/v2/{region}/music/most-played/20/songs.json. The old applemarketingtools domain is less reliable; most-recent/albums is 404 and must not be used as a release feed. Public ListenBrainz endpoints verified: /1/stats/sitewide/recordings?range=week&count=20 and /1/explore/fresh-releases?days=7&future=false. Deduplicate recording MBIDs in chart payloads. Parse dates/timestamps, enforce finite timeouts, and preserve source attribution. Network failure must never fabricate data or hide the requested section.

Online chart/release songs need an actual in-app action: resolve title/artist through the selected metadata provider and play a returned provider track, or open an in-app search using that title/artist when direct resolution is ambiguous. Never send an Apple ID, MusicBrainz ID, or YouTube ID as if it were an unrelated selected provider's track ID.

## MB3 ZIP import

The actual user archive is C:/Users/Admin/Desktop/MB3_Export/MB3_Playlists_Complete.zip. Seven playlists, 1186 source rows. They include individual JSON/CSV/M3U8 exports and aggregate duplicate exports; aggregate MB3_All_Playlists.json is authoritative when present. Preserve names, source identity, order, original YouTube IDs, Unicode, and playlist membership. Deduplicate within each playlist, not across all playlists. Reject invalid/path-traversal/excess-size archives. The existing pure Dart parser in work/EvanTube/lib/services/playlist_import/playlist_import.dart passed seven tests including the actual archive; preserve and reuse it.

Use native file_picker on iOS and parse bytes. Flow: select file, select playlists, match actual provider candidates with progress and cancel, allow user to select versions or skip unresolved rows, explicitly confirm before writing, create or merge destination online playlists, show counts and failures with retry. No live account writes during development verification. Existing archive and file_picker dependencies suffice. Do not add a backend or credentials.

Candidate matching may automatically choose only confidently compatible title/artist/duration results; unrelated results must stay unselected. Provider IDs are authoritative for online writes. Cache duplicate queries during one import. Batch additions in chunks of at most 50; deduplicate against existing provider IDs and selected candidates. Preserve created destination IDs for retry so partial failures do not create another playlist or re-add acknowledged tracks. Record original YouTube IDs in the import result, not as provider IDs. Saved remote playlists already refresh every 45 seconds for cross-device changes; preserve that contract.

## Verification and scope

Tests must exercise actual parsing, matching, write batching/retry, and public feed decoding/error behavior without a live account write. Add failing focused tests before nontrivial new behavior. Use the available Flutter/Dart SDK; run formatting and targeted analyzer checks, then meaningful combined tests. Report macOS/iOS build or on-device limitations honestly; Windows test success does not prove iOS runtime success. Keep source ready for later packaging after the icon design arrives. Do not push shared branches, trigger IPA workflows, or change app icon assets.
