import Foundation
import XCTest
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
        for message in ["HTTP 429", "quota exceeded", "rate limit", "server 503"] {
            XCTAssertEqual(PlaybackErrorCategory.classify(message), .serverError)
        }
        for category in [PlaybackErrorCategory.noInternet, .serverError, .authRequired, .verificationRequired, .sourceNotConfigured] {
            XCTAssertFalse(category.permitsReplacementSearch)
        }
        XCTAssertTrue(PlaybackErrorCategory.songRemoved.permitsReplacementSearch)
        XCTAssertTrue(PlaybackErrorCategory.regionBlocked.permitsReplacementSearch)

        // Official fallback always stays on youtube.com and only accepts a
        // verified 11-character video ID. No extracted stream or credentials.
        XCTAssertEqual(YouTubeOfficialPlaybackPolicy.watchURL(for: "AAAAAAAAAAA")?.absoluteString,
                       "https://www.youtube.com/watch?v=AAAAAAAAAAA")
        XCTAssertEqual(YouTubeOfficialPlaybackPolicy.watchURL(for: "BBBBBBBBBBB")?.host, "www.youtube.com")
        for invalid in ["", "AAAAAAAAAA", "https://evil.example/a", "漢漢漢漢漢漢漢漢漢漢漢", "A&B=C", "AAAAAAAAAAA/evil"] {
            XCTAssertNil(YouTubeOfficialPlaybackPolicy.watchURL(for: invalid))
        }

        // Public IPA carries no private playback source configuration.
        // A real InnerTube repository must not send any client/player requests.
        if !SecretsProvider.hasPlayerSourceConfiguration {
            let repository = PlayerRepository(api: InnerTubeAPI())
            do {
                _ = try await repository.resolveStreamDescriptor(
                    videoId: "AAAAAAAAAAA", quality: .medium, requestHeaders: [:])
                XCTFail("Unconfigured playback must stop locally, not attempt the network")
            } catch InnerTubeError.sourceNotConfigured {
                // Expected immediately before any network call.
            }
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
