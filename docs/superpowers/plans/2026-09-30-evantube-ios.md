# EvanTube iOS implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task by task. Follow each task's test cycle and commit scope.

**Goal:** Implement the approved native EvanTube dark UI, real online homepage and usable MB3 ZIP import, while holding installation-package production for the user's icon design.

**Architecture:** Reuse Flutter, Riverpod, the selected metadata plugin, the current playback controller and history database. Add one small public-feed client for Apple regional charts and ListenBrainz public weekly/release data. Keep import parsing and transfer logic pure Dart, and put the user confirmation and actual provider calls in an import page.

**Tech stack:** Existing Flutter/Dart, hooks_riverpod, shadcn_flutter, Dio, archive, file_picker and package:test. No new backend or dependency is required.

**Spec:** docs/superpowers/specs/2026-09-30-evantube-ios.md

## Global Constraints

- Do not build, export, upload, or publish an IPA or other installation package yet.
- Leave app icon assets unchanged until the user's design arrives.
- Do not modify the user's existing Android checkout or its uncommitted work.
- Use #080d15 background, #111b28 cards, #edf3ff text, #a4afc1 secondary text; accent #c174ff at 0%, #ac70ff at 50%, #729eff at 82%, #84dfff at 100%.
- Traditional Chinese labels match the approved preview. Purple must remain clearly visible.
- All six homepage sections remain visible with truthful loading, empty, auth-required and error/retry states. No FakeData may appear as real music.
- Regional charts are language plus REGION; regional data does not identify lyric language.
- Provider IDs are authoritative for playback and playlist writes. Never substitute foreign Apple/MusicBrainz/YouTube IDs.
- No live account writes during development verification. No credentials, app icon edits or pushes to shared branches.
- Run focused failing tests before nontrivial logic, then passing tests and targeted analyzer checks. Windows tests do not prove iOS runtime success.

## Task 1: Approved UI and real online homepage

**Files:**
- Create lib/components/evantube/neo_noir.dart, lib/services/evantube/home_feed.dart, lib/provider/evantube/home_feed.dart and lib/modules/home/sections/evantube_home.dart.
- Modify lib/pages/home/home.dart, lib/main.dart, lib/modules/root/spotube_navigation_bar.dart, lib/modules/root/bottom_player.dart, lib/modules/player/player_controls.dart and the player presentation files whose backgrounds/borders need the approved style.
- Test test/evantube_home_feed_test.dart.

**Interfaces:**
- Consumes existing history, authentication, metadata browse/release/search endpoints and playback controller. Trace their actual types before editing UI.
- Produces EvanTubeAccent({required Widget child}) and EvanTubeAccentBorder({required Widget child, BorderRadius? borderRadius}) in neo_noir.dart for both this task and the import page.
- Produces pure Dart OnlineMusicItem with id, title, artist, sourceUrl, artworkUrl, kind, releaseDate; OnlineMusicFeed with sourceName, sourceUrl, updatedAt, periodStart and items. Use nullable metadata where source fields are absent.
- Public-feed client exposes chart(String region), weekly(), releases({DateTime? now}) returning Future<OnlineMusicFeed>; accepts existing Dio for finite timeout/error tests. Parsing helpers parseAppleChart, parseWeeklyChart and parseFreshReleases may be top-level or static, but share these models.

- [ ] Write red public-feed tests using small fixture maps: Apple feed.updated plus feed.results containing name/artistName/url/artworkUrl100/id; a ListenBrainz payload with repeated recording_mbid must yield one row; fresh releases with past, today and future dates must exclude future rows and sort dates descending. Add malformed/empty payload and finite network failure coverage. Test meaningful behavior, not constant colors.

```dart
test('weekly rows deduplicate recording IDs without inventing entries', () {
  final raw = {'payload': {'from_ts': 1789948800, 'last_updated': 1790743833,
    'recordings': [
      {'recording_mbid':'recording-a','track_name':'Song A','artist_name':'Artist A','listen_count':9},
      {'recording_mbid':'recording-a','track_name':'Song A','artist_name':'Artist A','listen_count':9}
    ]}};
  final feed = parseWeeklyChart(raw);
  expect(feed.items.map((e) => e.id), ['recording-a']);
  expect(feed.periodStart, isNotNull);
});
```

- [ ] Run the focused tests before implementing helpers, record the expected failure in the report. Use the available Dart SDK F:/SDK/flutter/bin/cache/dart-sdk/bin/dart.exe and this checkout's .dart_tool/package_config.json. The pure-Dart test runner can use the test package's bin/test.dart resolved from package_config.json; no Flutter build is needed.
- [ ] Implement the feed models/decoders/client using actual source response shapes, preserving source/period data and request errors. Apple endpoint: https://rss.marketingtools.apple.com/api/v2/{region}/music/most-played/20/songs.json. ListenBrainz endpoints: https://api.listenbrainz.org/1/stats/sitewide/recordings?range=week&count=20 and https://api.listenbrainz.org/1/explore/fresh-releases?days=7&future=false. Use finite request timeouts and no latest-albums Apple URL. Model choices must cover the preview's language/regions and accurately expose further supported regions when verified.
- [ ] Use Riverpod FutureProviders for requests, reuse plugin browse sections for personalized recommendations and weekly personalized playlists, and use history database rows for recent music. Implement all six sections, language/region selector, source/time labels, retry and pull-to-refresh. Logged-out personalized sections show connection action to existing account/provider UI.
- [ ] Implement public row action by resolving title/artist through the selected provider or navigating to the actual in-app search route. Use returned provider tracks for playback; never play a foreign provider identifier. Source links are supplementary and do not replace the in-app action.
- [ ] Implement the shared accent widgets and midnight theme; apply to Tube, MORE THAN MUSIC, home search/history icons, bottom icons AND labels, actual playback progress and play/pause ring and accent button borders. The 最近播放 section's 媒體庫 link is secondary gray. Preserve playback, artwork, timestamps, selection and routing state. Native typography/layout should closely follow the approved screenshots at mobile widths without replacing actual content with placeholder examples.

```dart
class EvanTubeAccent extends StatelessWidget {
  final Widget child;
  const EvanTubeAccent({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (bounds) => const LinearGradient(
      colors: [Color(0xffc174ff),Color(0xffac70ff),Color(0xff729eff),Color(0xff84dfff)],
      stops: [0,.5,.82,1],
      begin: Alignment.centerLeft,end: Alignment.centerRight,
    ).createShader(bounds),
    child: child,
  );
}
```

- [ ] Format changed files, run focused feed tests green and analyze all changed application files. Report baseline errors separately; resolve errors introduced by this task. Self-review and commit only Task 1 changes with message feat: implement EvanTube Neo Noir homepage and playback UI.

## Task 2: End-to-end MB3 ZIP playlist import

**Files:**
- Preserve lib/services/playlist_import/playlist_import.dart and test/playlist_import_test.dart (copied from the earlier verified parser).
- Copy and implement lib/services/playlist_import/playlist_import_transfer.dart and test/playlist_import_transfer_test.dart from C:/Users/Admin/Documents/Codex/2026-09-30/ios/work/EvanTube.
- Create lib/pages/library/playlist_import.dart.
- Modify lib/pages/library/user_playlists.dart to provide the native ZIP import entry point, and any minimal existing playlist-provider invalidation needed to refresh newly saved playlists.

**Interfaces:**
- Consumes Task 1's EvanTubeAccent and EvanTubeAccentBorder. Do not modify the public feed client or approved theme during this task.
- Existing parser entry point parsePlaylistImport(bytes, filename: name) returns PlaylistImportDocument(playlists, warnings, rowCount).
- Preserve the existing transfer classes and signatures verbatim: matchPlaylistImport(playlists, search, {onProgress, isCancelled}); writePlaylistImport(matches, {create, loadTrackIds, addTracks, targets, onProgress}). Their current stubs and four red tests are in the earlier work/EvanTube copy.
- Actual provider adapters in the page must use the existing metadata plugin's typed search/create/list/add endpoints. Destination target IDs survive retries and cancellation of writing cannot erase acknowledged success.

- [ ] Run the seven existing parser tests (set MB3_TEST_ZIP to C:/Users/Admin/Desktop/MB3_Export/MB3_Playlists_Complete.zip), then copy and run the four existing transfer tests red. Record exact failure/output before implementing transfer logic.
- [ ] Implement query cleaning/caching and conservative candidate selection. Keep source track and YouTube IDs intact in matches. Use title/artist/duration compatibility; leave unrelated/ambiguous candidates unselected. Report progress for every attempted row and cancel before another request starts. Do not swallow errors as a successful match.
- [ ] Implement create/merge writes: reload existing provider IDs; deduplicate selected IDs, skip unresolved rows, add batches of at most 50; persist created targets immediately before adding; on failure report acknowledged additions and preserve destination so retry reloads IDs instead of creating another playlist. Continue independent playlists after one failure.
- [ ] Implement a native file_picker ZIP byte-reading page with file-size validation, parsed playlist checkbox selection, match progress/cancel, candidate/version confirmation and skipped-row count. Provide destination new/merge selection. The user explicitly confirms before any create/add call. Show final per-playlist counts and error/retry, preserving same targets. Retain original source IDs in the report and never upload them as provider IDs. Keep all write tests isolated through supplied callbacks, no live credentials or account write.
- [ ] Add the import entry in the media library toolbar using direct navigation consistent with the repository. A local MaterialPageRoute/dialog is acceptable to avoid unnecessary router code generation. Reuse existing native dependencies and Task 1 styling. Preserve existing shared-playlist provider refresh semantics.
- [ ] Run focused transfer tests green; extend tests for cancellation, search errors, ambiguity, intra-playlist vs inter-playlist duplicates, successful batch writes and partial failure/retry. Run parser and transfer tests together, format, and analyze all touched application files. Self-review and commit only Task 2 changes with message feat: import MB3 ZIP playlists through metadata provider.

## Completion checks

Run the combined new/modified tests and targeted analyzer on integrated code, and compare touched-file behavior against the approved UI source and this spec. A fresh reviewer examines the whole branch after task reviews. Preserve source changes and report remaining platform limitations honestly. Do not invoke IPA, archive, upload, publish or app-icon generation. The user's icon design is the only reason installation packaging remains pending.
