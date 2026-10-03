# Build 9: playback verification after pause

Status: the app-side recovery repairs passed 115 native simulator tests and source review. The YouTube verification trigger remains unresolved on the affected device. The user requested no IPA/APK generation; none was produced by these workflows.

## Evidence

The user supplied a build 9, version 1.0.0 diagnostic export and the matching verification alert. The export contains 100 events and no storage error. Times below are Asia/Taipei on 2026-10-03. Do not commit the raw attachment, credentials, cookies, or device identifiers.

| Time | Observed event |
| --- | --- |
| 09:45:09 | The affected video resolves successfully through the visionOS client, with HLS available. |
| 09:45:11 | The engine is ready and playing. |
| 09:49:40 | Remote pause at approximately 269 seconds. |
| 09:49:42 | Audio interruption begins. The retained trace has no interruption-ended event before the next selection. |
| 10:36:57 | The same video is selected with the preserved 269-second position. |
| 10:36:58–59 | Both visionOS and the session-based iOS request return HTTP 200, `LOGIN_REQUIRED`, `verificationRequired`, zero formats, and no HLS. |
| 10:37:09–10 | Retry repeats the rejection through both clients. The retry selection starts at zero; this is a separate observation, not proof of the remote rejection's cause. |

The session-based request carries authentication material (`hasAuth=true`) and follows a watch-page bootstrap with session age zero on both failed attempts. This shows a newly bootstrapped request with cookies present; it does **not** prove those cookies were accepted as a valid login by YouTube.

The configured iOS and Web Remix fallback attempts stop with `sourceNotConfigured` before sending their player requests. The export reports `playerSourceConfigured=false`. These playback settings are separate from the YouTube Data API search key.

## Hypotheses checked

1. **YouTube rejects the playback request for verification.** Supported: four server responses have no playable formats and a verification reason. `PlaybackDiagnostics.Reason.classify` maps the server's bot-verification text to this category. The trace cannot identify whether the trigger is network reputation, account/session validity, or client characteristics.
2. **Only an old watch-session bootstrap causes the failure.** Insufficient: both fresh session-based requests remain rejected. Existing authentication material may still be invalid; the sanitized diagnostic intentionally cannot reveal credentials.
3. **A fallback can recover, but its source configuration is absent.** Configuration absence confirmed. Whether configured fallbacks would succeed is untested; adding configuration is not evidence that verification will disappear.

The trace demonstrates successful playback and then rejection for the same video. It does not establish a permanent regional restriction, a playlist-storage failure, a search-quota failure, or every video's current playability.

## User follow-up: web playback works

The user confirmed that the app's visible YouTube watch-page playback works during this incident. The failure is therefore specific to the native stream-resolution requests in the captured session; it is not a blanket inability to play the video through YouTube. Successful browser playback does not prove that the separate native requests have accepted authentication or verification.

The original source had a session handoff gap: the watch page received Keychain cookies but did not save updated browser cookies back into `YouTubeAuthManager`. This app defect was reproduced and repaired. It remains a **candidate contributor** to this incident, not a proven cause of YouTube's rejection: the sanitized export contains no cookie values or rotation evidence.

## Verification performed

A read-only replay assertion against the supplied JSON passed: four HTTP 200 verification responses, zero formats/no HLS, two fresh session requests with authentication material, an earlier successful resolution for the same video, four unconfigured fallback attempts during the incident, and no reported storage error. This validates the captured evidence, not live playback or a production fix.

Source inspection confirms the shared fallback chain in `PlayerRepository.resolveStreamDescriptorUncached`, request recording in `InnerTube.executePlayerRequest`, session bootstrap in `InnerTube.playerWithSession`, and separate search/player settings in `SecretsProvider`. Existing session reset and watch-page refresh already run along this path.

## App recovery repairs

- Browser dismissal now saves valid updated cookies through the existing authentication manager and notifies native API observers. A session revision prevents an old web view from undoing logout or overwriting a newer login. Diagnostics record only the typed `webSessionUpdated` event, never cookie values.
- Opening web playback pauses the native engine without clearing the queue or saved progress. Manual retry resolves a fresh stream while retaining that position, shuffle, and queue.
- Native regression run [37092303921](https://github.com/c63amg77771717-commits/spotube/actions/runs/37092303921) reproduced the missing cookie handoff and zero-second retry. Run [37093039710](https://github.com/c63amg77771717-commits/spotube/actions/runs/37093039710) passed 113 tests after those repairs, including logout/new-login protection. Its uploaded artifact list was empty.
- Review identified and reproduced two additional defects: an untracked delayed retry can restart native playback behind the web page; raw fMP4 readiness can consume the deferred seek before the seekable remux is installed. Valid red run [37095066191](https://github.com/c63amg77771717-commits/spotube/actions/runs/37095066191) compiled and executed 115 tests, with three expected assertion failures across these two cases. The actual fragmented-audio fixture became ready and completed remux/seek/playback; its failure was premature target consumption, not incorrect physical seeking.
- Delayed retries now use the existing cancellable task slot and check the failed song and error before running. Manual retry cancels older scheduled work. Raw readiness now keeps the seek target for remux handoff.
- Final green run [37095517704](https://github.com/c63amg77771717-commits/spotube/actions/runs/37095517704) at source commit `8ea8c16b` passed all 115 tests with zero failures. The six web recovery cases passed, including stale retry cancellation, raw readiness retaining the target, actual remuxed AVPlayer seeking to 12 seconds, and playback advancing from that position while preserving the earlier explicit pause. Final source review found no additional material issues. The run's uploaded artifact list was empty.

The initial deterministic audio generator timed out, and two fixture edits failed compilation. Those runs are excluded from behavioral RED/GREEN evidence. The final fixture uses native passthrough AAC writing from bundled audio, verifies actual movie fragments, and goes through the production remux and player methods.

All runs use `.github/workflows/evantube-native-ios-tests.yml` on the dedicated test branch, with example configuration and no online credentials. This workflow has no archive, IPA/APK packaging, or artifact-upload steps. Source tests do not establish that YouTube accepts the resulting player request.

## Next verification

- The user has confirmed the app's visible watch-page fallback works during this incident.
- Verify returning from web verification and manually retrying native playback. Do not assume successful web playback also restores native background or lock-screen playback.
- The user has now requested a repaired iOS IPA: build 10 will include these source repairs after the packaging workflow's native and UI gates pass. Device acceptance of the native player request remains a separate check after installation.
- Do not label this incident fixed on the basis of a renamed error, more retries, or passing offline tests. Verify the recovery on the affected phone.
