import Foundation
import XCTest
import AVFoundation
@testable import LovelyMusic

@MainActor
final class PlaybackSourceReplacementTests: XCTestCase {
    private func song(_ id: String = "AAAAAAAAAAA", title: String = "Synthetic Song A",
                      artist: String = "Synthetic Artist A", verified: Bool = true) -> Song {
        var value = Song(id: id, title: title, artistName: artist, artistId: nil,
                         albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
        value.artistNameSource = verified ? .artistMetadata : .uploader
        return value
    }

    private func store() -> (PlaybackSourceReplacementStore, UserDefaults) {
        let suite = "evantube.synthetic.source.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (PlaybackSourceReplacementStore(defaults: defaults), defaults)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Synthetic asynchronous operation did not reach its checkpoint")
        throw URLError(.timedOut)
    }

    func testPrefillUsesOnlyCurrentArtistAndTitleAndDoesNotSearchDuringInit() {
        var calls = 0
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: []) { _ in
            calls += 1
            return []
        }
        XCTAssertEqual(model.query, "Synthetic Artist A Synthetic Song A")
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testVerifiedIdentityRanksFirstAndUploaderNameRemainsUncertain() {
        let uploader = song("BBBBBBBBBBB", verified: false)
        let verified = song("CCCCCCCCCCC")
        let result = PlaybackSourceReplacementPolicy.candidates([uploader, verified], for: song(), excluding: [])
        XCTAssertEqual(result.map(\.id), [verified.id, uploader.id])
        XCTAssertEqual(result.first?.match, .sameIdentity)
        XCTAssertEqual(result.last?.match, .needsReview)
        // Playlist-specific search never auto-applies and filters songs with
        // known different artists or titles.
        let scoped = PlaylistSourceIdentityPolicy.candidates([
            uploader, verified, song("DDDDDDDDDDD", title: "Different Song"),
            song("EEEEEEEEEEE", artist: "Wrong Artist")
        ], original: song(), excluding: [])
        XCTAssertEqual(scoped.map(\.id), [verified.id, uploader.id])
        XCTAssertEqual(scoped.first?.match, .sameIdentity)
        XCTAssertEqual(scoped.last?.match, .needsReview)
    }

    func testCoverLiveAndRemixAreNeverRankedAsConfirmedIdentity() {
        let values = [song("BBBBBBBBBBB", title: "Synthetic Song A (Cover)"),
                      song("CCCCCCCCCCC", title: "Synthetic Song A Live"),
                      song("DDDDDDDDDDD", title: "Synthetic Song A Remix")]
        let result = PlaybackSourceReplacementPolicy.candidates(values, for: song(), excluding: [])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.match == .differentVersion })
        let olive = song("EEEEEEEEEEE", title: "Synthetic Olive Song")
        XCTAssertEqual(PlaybackSourceReplacementPolicy.candidates([olive], for: song(), excluding: []).first?.match, .needsReview)
    }

    func testInvalidDuplicateOriginalAndAlreadySelectedSourcesAreExcluded() {
        let values = [song(), song("BBBBBBBBBBB"), song("BBBBBBBBBBB"),
                      song("CCCCCCCCCCC"), song("https://fixture.invalid/media"), song("漢漢漢漢漢漢漢漢漢漢漢")]
        let result = PlaybackSourceReplacementPolicy.candidates(values, for: song(), excluding: ["AAAAAAAAAAA", "CCCCCCCCCCC"])
        XCTAssertEqual(result.map(\.id), ["BBBBBBBBBBB"])
    }

    func testOnlyIDsPersistAndRestoringSurvivesReload() throws {
        let (store, defaults) = store()
        try store.save(sourceID: "BBBBBBBBBBB", for: "AAAAAAAAAAA")
        let data = try XCTUnwrap(defaults.data(forKey: PlaybackSourceReplacementStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: data), ["AAAAAAAAAAA": "BBBBBBBBBBB"])
        let reload = PlaybackSourceReplacementStore(defaults: defaults)
        XCTAssertEqual(reload.sourceID(for: "AAAAAAAAAAA"), "BBBBBBBBBBB")
        try reload.restore(originalID: "AAAAAAAAAAA")
        XCTAssertEqual(PlaybackSourceReplacementStore(defaults: defaults).sourceID(for: "AAAAAAAAAAA"), "AAAAAAAAAAA")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evantube-scoped-" + UUID().uuidString)
        let file = root.appendingPathComponent("overrides.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = PlaylistSourceOverrideStore(fileURL: file)
        let original = song().inPlaylist("playlist-A")
        let candidate = song("BBBBBBBBBBB")
        XCTAssertEqual(try scoped.save(candidate: candidate, playlistID: "playlist-A",
                                       originalID: original.id, expectedRevision: 0).revision, 1)
        XCTAssertEqual(scoped.sourceID(for: original, legacy: { _ in original.id }), candidate.id)
        XCTAssertEqual(scoped.sourceID(for: song().inPlaylist("playlist-B"),
                                      legacy: { _ in original.id }), original.id)
        XCTAssertThrowsError(try scoped.save(candidate: song("CCCCCCCCCCC"),
                                            playlistID: "playlist-A", originalID: original.id,
                                            expectedRevision: 0))
        let reloaded = PlaylistSourceOverrideStore(fileURL: file)
        XCTAssertEqual(reloaded.sourceID(for: original, legacy: { _ in original.id }), candidate.id)
        try reloaded.restore(playlistID: "playlist-A", originalID: original.id, expectedRevision: 1)
        XCTAssertEqual(reloaded.sourceID(for: original, legacy: { _ in candidate.id }), original.id)
    }

    func testStoreRejectsURLsUnicodeIDsAndSelfReplacement() throws {
        let (store, _) = store()
        for id in ["https://fixture.invalid/media", "漢漢漢漢漢漢漢漢漢漢漢", "AAAAAAAAAAA"] {
            XCTAssertThrowsError(try store.save(sourceID: id, for: "AAAAAAAAAAA"))
        }
        XCTAssertFalse(store.hasReplacement(for: "AAAAAAAAAAA"))
    }

    func testResolverUsesSelectedSourceWithoutChangingOriginalIdentity() async throws {
        let (store, _) = store()
        try store.save(sourceID: "BBBBBBBBBBB", for: "AAAAAAAAAAA")
        var requested: [String] = []
        let result = try await store.resolve(originalID: "AAAAAAAAAAA") { id in
            requested.append(id)
            return "synthetic-result"
        }
        XCTAssertEqual(requested, ["BBBBBBBBBBB"])
        XCTAssertEqual(result, "synthetic-result")
        XCTAssertEqual(store.sourceID(for: "CCCCCCCCCCC"), "CCCCCCCCCCC")
        let scopedFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: scopedFile) }
        let scoped = PlaylistSourceOverrideStore(fileURL: scopedFile)
        let entry = song().inPlaylist("playlist-A")
        try scoped.save(candidate: song("DDDDDDDDDDD"), playlistID: "playlist-A",
                        originalID: entry.id, expectedRevision: 0)
        let value = try await scoped.resolve(song: entry, legacy: { store.sourceID(for: $0) }) { source in
            XCTAssertEqual(source, "DDDDDDDDDDD")
            return source
        }
        XCTAssertEqual(value, "DDDDDDDDDDD")
        XCTAssertEqual(entry.id, "AAAAAAAAAAA")
    }

    func testChangingSourceAwayAndBackRejectsLateResolution() async throws {
        let (store, _) = store()
        try store.save(sourceID: "BBBBBBBBBBB", for: "AAAAAAAAAAA")
        var continuation: CheckedContinuation<String, Never>?
        let task = Task {
            try await store.resolve(originalID: "AAAAAAAAAAA") { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await waitFor { continuation != nil }
        try store.save(sourceID: "CCCCCCCCCCC", for: "AAAAAAAAAAA")
        try store.save(sourceID: "BBBBBBBBBBB", for: "AAAAAAAAAAA")
        continuation?.resume(returning: "stale-synthetic-result")
        do { _ = try await task.value; XCTFail("A previous source epoch must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellingSearchRejectsLateResult() async throws {
        let probe = SyntheticReplacementSearchProbe()
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: [], searcher: probe.search)
        let task = Task { await model.search() }
        try await waitFor { probe.requests.count == 1 }
        model.cancel()
        probe.finish(0, with: [song("BBBBBBBBBBB")])
        await task.value
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testEditedQueryAndSlowPreviousResultsCannotOverwriteNewSearch() async throws {
        let probe = SyntheticReplacementSearchProbe()
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: [], searcher: probe.search)
        let first = Task { await model.search() }
        try await waitFor { probe.requests.count == 1 }
        model.query = "Synthetic Artist B Synthetic Song B"
        let second = Task { await model.search() }
        try await waitFor { probe.requests.count == 2 }
        probe.finish(1, with: [song("CCCCCCCCCCC")])
        await second.value
        probe.finish(0, with: [song("BBBBBBBBBBB")])
        await first.value
        XCTAssertEqual(model.candidates.map(\.id), ["CCCCCCCCCCC"])
    }

    func testChangingPlaybackSessionRejectsLateResultEvenForTheSameSongID() async throws {
        let probe = SyntheticReplacementSearchProbe()
        var isCurrent = true
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: [], contextIsCurrent: { isCurrent }, searcher: probe.search)
        let task = Task { await model.search() }
        try await waitFor { probe.requests.count == 1 }
        isCurrent = false
        probe.finish(0, with: [song("BBBBBBBBBBB")])
        await task.value
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isLoading)
    }

    func testOfflineQuotaAndAuthSearchFailuresDoNotRetryOrMutateOriginal() async {
        let original = song()
        for error in [YouTubeSearchError.networkUnavailable, .quotaExceeded, .keyRejected] {
            var calls = 0
            let model = ReplacementSourceSearchModel(original: original, excludedIDs: []) { _ in
                calls += 1
                throw error
            }
            await model.search()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.original, original)
            XCTAssertTrue(model.candidates.isEmpty)
            XCTAssertFalse(model.isLoading)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testSourceAndExpiringURLAreExcludedFromSongPersistence() throws {
        var value = song()
        value.resolvedSourceID = "BBBBBBBBBBB"
        value.streamURL = "https://fixture.invalid/temporary"
        let data = try JSONEncoder().encode(value)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(encoded["id"] as? String, "AAAAAAAAAAA")
        XCTAssertEqual(encoded["title"] as? String, "Synthetic Song A")
        XCTAssertNil(encoded["resolvedSourceID"])
        XCTAssertNil(encoded["streamURL"])
    }

    func testPreparingChangedOrRestoredSourceClearsStaleURLAndKeepsMetadata() {
        let engine = AudioEngine()
        var value = song()
        value.streamURL = "https://fixture.invalid/old"
        engine.playbackSourceIDResolver = { _ in "BBBBBBBBBBB" }
        let replacement = engine.sourcePreparedSong(value)
        XCTAssertEqual(replacement.id, value.id)
        XCTAssertEqual(replacement.title, value.title)
        XCTAssertEqual(replacement.artistName, value.artistName)
        XCTAssertEqual(replacement.resolvedSourceID, "BBBBBBBBBBB")
        XCTAssertNil(replacement.streamURL)
        engine.playbackSourceIDResolver = { $0 }
        var fresh = replacement
        fresh.streamURL = "https://fixture.invalid/selected"
        XCTAssertNil(engine.sourcePreparedSong(fresh).streamURL)
    }

    func testGlobalFailureCategoriesDoNotOfferSongInvalidation() async throws {
        for message in ["verificationRequired", "LOGIN_REQUIRED: verificationRequired",
                        "Sign in to confirm you\'re not a bot"] {
            XCTAssertEqual(PlaybackErrorCategory.classify(message), .verificationRequired)
        }
        XCTAssertEqual(PlaybackErrorCategory.classify("LOGIN_REQUIRED"), .authRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("sourceNotConfigured"), .sourceNotConfigured)
        XCTAssertEqual(PlaybackErrorCategory.classify("HTTP error: 400"), .requestRejected)
        XCTAssertEqual(PlaybackErrorCategory.classify("HTTP 錯誤：400"), .requestRejected)
        for message in ["HTTP 429", "quota exceeded", "rate limit", "server 503"] {
            XCTAssertEqual(PlaybackErrorCategory.classify(message), .serverError)
        }
        for category in [PlaybackErrorCategory.noInternet, .serverError, .requestRejected, .authRequired, .verificationRequired, .sourceNotConfigured] {
            XCTAssertFalse(category.permitsReplacementSearch)
        }
        XCTAssertTrue(PlaybackErrorCategory.songRemoved.permitsReplacementSearch)
        XCTAssertTrue(PlaybackErrorCategory.regionBlocked.permitsReplacementSearch)

        // Native playback authenticates with the existing user-issued session.
        // No authorization may be synthesized for an unauthenticated request.
        XCTAssertNil(YouTubeAuthManager.sessionAuthorizationHeader(
            cookieHeader: nil, origin: "https://www.youtube.com", timestamp: 1234))
        XCTAssertNil(YouTubeAuthManager.sessionAuthorizationHeader(
            cookieHeader: "SID=synthetic", origin: "https://www.youtube.com", timestamp: 1234))
        let signed = YouTubeAuthManager.sessionAuthorizationHeader(
            cookieHeader: "SID=synthetic; SAPISID=fixture-only",
            origin: "https://www.youtube.com", timestamp: 1234)
        XCTAssertTrue(signed?.hasPrefix("SAPISIDHASH 1234_") == true)
        XCTAssertFalse(signed?.contains("fixture-only") == true)
        XCTAssertNil(YouTubeAuthManager.sessionAuthorizationHeader(
            cookieHeader: "SAPISID=fixture-only", origin: "https://evil.invalid", timestamp: 1234))
        // Intercept both watch and player requests: an already-issued signed
        // account header must reach the actual native IOS POST.
        let storage = HTTPCookieStorage.shared
        let saved = storage.cookies ?? []
        defer {
            for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
            for cookie in saved { storage.setCookie(cookie) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativePlaybackAuthFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = InnerTubeAPI(session: session)
        await api.setCookie("SID=synthetic-session; SAPISID=synthetic-secret")
        let player = try await api.playerWithSession(videoId: "AAAAAAAAAAA")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: player) as? [String: Any])
        XCTAssertEqual((object["playabilityStatus"] as? [String: String])?["status"], "OK")
        // End-to-end from the native IOS session through AVPlayer's stream
        // descriptor path, with every network call intercepted locally.
        let repository = PlayerRepository(api: api)
        let descriptor = try await repository.resolveStreamDescriptor(
            videoId: "AAAAAAAAAAA", quality: .medium, requestHeaders: [:])
        XCTAssertEqual(descriptor.videoID, "AAAAAAAAAAA")
        XCTAssertEqual(descriptor.remoteURL.host, "cdn.example")
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        // The rendered iOS Control Center must be bound to this AVPlayer.
        let nowPlayingAVPlayer = AVPlayer()
        let nowPlaying = NowPlayingManager()
        let mediaSession = nowPlaying.attachPlayer(nowPlayingAVPlayer)
        XCTAssertTrue(mediaSession.players.first === nowPlayingAVPlayer)
        XCTAssertFalse(mediaSession.automaticallyPublishesNowPlayingInfo)
        let commands = RemoteCommandManager()
        commands.bind(session: mediaSession)
        XCTAssertTrue(mediaSession.remoteCommandCenter.playCommand.isEnabled)
        XCTAssertTrue(mediaSession.remoteCommandCenter.nextTrackCommand.isEnabled)
        commands.tearDown()
        mediaSession.nowPlayingInfoCenter.nowPlayingInfo = nil
        // Build27 field diagnostic: IOS(session) answered HTTP 400 despite a
        // valid watch session. An available, in-app HTTPS HLS stream must be
        // usable without configured optional client keys.
        let hlsRecovered = try await PlayerRepository(api: NativeSessionHTTP400HLSFixture(
            hlsAvailable: true
        )).resolveStreamDescriptor(videoId: "AAAAAAAAAAA", quality: .medium, requestHeaders: [:])
        XCTAssertEqual(hlsRecovered.remoteURL.absoluteString, "https://cdn.example/audio.m3u8")
        XCTAssertEqual(hlsRecovered.mimeType, "application/x-mpegURL")

        // If VisionOS reaches YouTube but the content itself is UNPLAYABLE,
        // that song-level result must beat the earlier IOS HTTP 400.
        do {
            _ = try await PlayerRepository(api: NativeSessionHTTP400HLSFixture(
                hlsAvailable: false
            )).resolveStreamDescriptor(videoId: "AAAAAAAAAAA", quality: .medium, requestHeaders: [:])
            XCTFail("VisionOS UNPLAYABLE must be preserved over IOS HTTP 400")
        } catch InnerTubeError.videoUnavailable(let reason) {
            XCTAssertTrue(reason.lowercased().contains("unavailable"))
        }
    }

    func testRepeatedSearchAllowsOnlyTheLatestSelection() async throws {
        let probe = SyntheticReplacementSearchProbe()
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: [], searcher: probe.search)
        let first = Task { await model.search() }
        try await waitFor { probe.requests.count == 1 }
        let second = Task { await model.search() }
        try await waitFor { probe.requests.count == 2 }
        probe.finish(0, with: [song("BBBBBBBBBBB")])
        await first.value
        XCTAssertTrue(model.candidates.isEmpty)
        probe.finish(1, with: [song("CCCCCCCCCCC")])
        await second.value
        let candidate = try XCTUnwrap(model.candidates.first)
        XCTAssertTrue(model.contains(candidate))
        model.query = "Synthetic revised query"
        XCTAssertFalse(model.contains(candidate))
    }

    func testEmptyQueryMakesNoProviderRequest() async {
        var calls = 0
        let model = ReplacementSourceSearchModel(original: song(), excludedIDs: []) { _ in calls += 1; return [] }
        model.query = "  "
        await model.search()
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(model.errorMessage)
    }
}

@MainActor
private final class SyntheticReplacementSearchProbe {
    var requests: [String] = []
    private var pending: [Int: CheckedContinuation<[Song], Error>] = [:]
    func search(_ query: String) async throws -> [Song] {
        let index = requests.count
        requests.append(query)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, with songs: [Song]) {
        pending.removeValue(forKey: index)?.resume(returning: songs)
    }
}

private final class NativePlaybackAuthFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { XCTFail("No synthetic native URL"); return }
        XCTAssertEqual(url.host, "www.youtube.com")
        let isPlayer = request.httpMethod == "POST"
        let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertEqual(cookies.components(separatedBy: "; ").filter { $0.hasPrefix("SID=") },
                       ["SID=synthetic-session"])
        if isPlayer {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(authorization?.hasPrefix("SAPISIDHASH ") == true)
            XCTAssertFalse(authorization?.contains("synthetic-secret") == true)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = isPlayer
            ? #"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{"itag":140,"url":"https://cdn.example/descriptor.mp4","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000,"contentLength":"4000000","approxDurationMs":"245678","initRange":{"start":"0","end":"699"},"indexRange":{"start":"700","end":"1199"}}]}}"#
            : #"<html><script>{"visitorData":"fixture"}</script></html>"#
        client?.urlProtocol(self, didLoad: Data(bytes.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Offline-only native playback probe, including an actual HTTP 400 from the
/// first client and an independently available HLS response. No live traffic.
private struct NativeSessionHTTP400HLSFixture: PlayerAPIClient {
    let hlsAvailable: Bool

    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data {
        throw InnerTubeError.httpError(statusCode: 400)
    }
    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data {
        throw InnerTubeError.httpError(statusCode: 403)
    }
    func playerWithVisionOS(videoId: String) async throws -> Data {
        if hlsAvailable {
            return Data(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"hlsManifestUrl":"https://cdn.example/audio.m3u8"}}"#.utf8)
        }
        return Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"unavailable"}}"#.utf8)
    }
    func resetSession() async {}
}
