import Foundation
import XCTest
@testable import LovelyMusic

final class Build20LyricsTests: XCTestCase {
    func testOrdinaryGet404FallsBackToSearchWithOriginalIdentity() async throws {
        let f = Build20Transport { request in
            request.url!.lastPathComponent == "search" ? .json([Self.primary()]) : .status(404)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(result?.selectionKey, "song:video000001")
        XCTAssertEqual(f.requests.map { $0.url!.lastPathComponent }, ["get", "get", "search"])
    }

    func testGetIdentityMismatchSearchesAndNeverDisplaysWrongSinger() async throws {
        let f = Build20Transport { request in
            if request.url!.lastPathComponent == "search" { return .json([Self.primary()]) }
            var wrong = Self.primary(); wrong["artistName"] = "Different performer"
            return .json(wrong)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.candidates.map(\.artist), ["Fixture performer"])
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(f.requests.last?.url?.lastPathComponent, "search")
    }

    func testSecondaryUsesCommonAliasAndScriptScoringWithoutExactStringPrefilter() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "jay-1", "title": "晴天", "artist": "Jay Chou", "duration": 200, "lrc": "[00:01.00]晴天歌詞"],
            ["id": "wrong", "title": "晴天", "artist": "Different performer", "duration": 200, "lyrics": "Wrong singer"]
        ]) }
        defer { f.close() }
        let c = context(title: "晴天", artist: "周杰倫")
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["jay-1"])
        XCTAssertEqual(result?.lines.first?.text, "晴天歌詞")
        XCTAssertEqual(f.requests.count, 1)
    }

    func testCollaborationsNormalizeFeatSeparatorsAndRetainPrimaryPerformer() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(artist: "Artist A feat. Artist B")))
        XCTAssertNotNil(LyricsCandidateScorer.score(candidate(artist: "Artist A & Artist B"), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(artist: "Artist B & Artist A"), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(artist: "Artist A & Artist C"), metadata: metadata))
        let incomplete = try XCTUnwrap(LyricsCandidateScorer.choose([candidate(artist: "Artist A")], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertTrue(incomplete.lines.isEmpty)
        XCTAssertEqual(incomplete.candidates.count, 1)
    }

    func testEveryVersionTagSurvivesNoiseRemovalAndRejectsStudioRecording() throws {
        for version in ["Live", "Remix", "Acoustic", "Cover", "Instrumental", "Karaoke", "Demo", "Remastered",
                        "Sped Up", "Slowed", "Nightcore", "Radio Edit", "Extended", "Original Mix", "Edit", "Version", "Live Session", "Concert"] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(title: "Fixture song (\(version)) (Official Video) [4K]", video: true)))
            XCTAssertTrue(metadata.pair.title.contains(version))
            XCTAssertFalse(metadata.versionTags.isEmpty, version)
            XCTAssertNil(LyricsCandidateScorer.score(candidate(), metadata: metadata), version)
            XCTAssertNotNil(LyricsCandidateScorer.score(candidate(title: "Fixture song (\(version))"), metadata: metadata), version)
        }
    }

    func testOnlyPurePresentationLabelsAreRemoved() {
        XCTAssertEqual(LyricsCanonicalMetadata.presentationTitle("Song (Official Video) [HD] Visualizer"), "Song")
        for title in ["Song (Live Official MV)", "Song [Remix Lyric Video]", "Song Unofficial Music Video", "Song HD Remix"] {
            XCTAssertEqual(LyricsCanonicalMetadata.presentationTitle(title), title)
        }
    }

    func testDurationMismatchRetainsIdentityButDowngradesAllTimestampsToPlain() async throws {
        let f = Build20Transport { request in
            var record = Self.primary(); record["duration"] = 230
            return .json(request.url!.lastPathComponent == "search" ? [record] : record)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.map(\.text), ["Fixture lyric"])
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertTrue(result?.lines.allSatisfy { $0.time == 0 } ?? false)
    }

    func testCloseScoresRequireManualChoiceAndAlbumCanIdentifyUniqueHighCandidate() throws {
        let defaults = isolatedDefaults()
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(album: "Original Album")))
        let first = candidate(id: "1", duration: 200)
        let close = candidate(id: "2", duration: 205)
        let manual = try XCTUnwrap(LyricsCandidateScorer.choose([first, close], metadata: metadata, defaults: defaults))
        XCTAssertTrue(manual.lines.isEmpty)
        XCTAssertEqual(manual.candidates.count, 2)
        let album = candidate(id: "2", duration: 200, album: "Original Album")
        let unique = try XCTUnwrap(LyricsCandidateScorer.choose([first, album], metadata: metadata, defaults: defaults))
        XCTAssertEqual(unique.lines.first?.text, "Record 2")
    }

    func testSelectionsBelongToSongIDAcrossMetadataChangesAndDoNotLeakToAnotherVideo() throws {
        let defaults = isolatedDefaults()
        let a = context(id: "video000001")
        let b = context(id: "video000002")
        let records = [candidate(id: "1"), candidate(id: "2")]
        LyricsSelectionStore.select(records[1].id, for: a.selectionKey, defaults: defaults)
        let changed = context(id: a.songID!, duration: 205)
        let restored = try XCTUnwrap(LyricsCandidateScorer.choose(records, metadata: XCTUnwrap(LyricsCanonicalMetadata(changed)), defaults: defaults))
        XCTAssertEqual(restored.lines.first?.text, "Record 2")
        let other = try XCTUnwrap(LyricsCandidateScorer.choose(records, metadata: XCTUnwrap(LyricsCanonicalMetadata(b)), defaults: defaults))
        XCTAssertTrue(other.lines.isEmpty)
        XCTAssertNil(LyricsSelectionStore.selectedRecord(for: b.selectionKey, defaults: defaults))
    }

    func testLegacyChoiceMigratesOnlyAfterRecordPassesIdentityValidation() throws {
        let defaults = isolatedDefaults()
        let c = context()
        let selected = candidate(id: "2")
        LyricsSelectionStore.select(selected.id, for: c.legacySelectionKey, defaults: defaults)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertNil(LyricsCandidateScorer.choose([candidate(id: "2", artist: "Wrong singer")], metadata: metadata, defaults: defaults))
        XCTAssertNil(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: defaults))
        _ = LyricsCandidateScorer.choose([selected], metadata: metadata, defaults: defaults)
        XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: defaults), selected.id)
    }

    func testRememberedLRCLibRecordIsRevalidatedByIDBeforeAnyMetadataSearch() async throws {
        let f = Build20Transport { _ in .json(Self.primary()) }
        defer { f.close() }
        let c = context()
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "1"), for: c.selectionKey, defaults: f.defaults)
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(f.requests.count, 1)
        XCTAssertEqual(f.requests.first?.url?.path, "/api/get/1")
    }

    func testInvalidRememberedRecordFallsBackToBoundedMetadataLookup() async throws {
        let f = Build20Transport { request in
            var record = Self.primary()
            if request.url!.lastPathComponent == "9" { record["id"] = 9; record["artistName"] = "Wrong singer" }
            return .json(record)
        }
        defer { f.close() }
        let c = context()
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "9"), for: c.selectionKey, defaults: f.defaults)
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.first?.recordID, "1")
        XCTAssertEqual(f.requests.count, 2)
    }

    func testSecondaryDisabledMakesNoSecondaryRequestAndRetainsStoredChoice() async throws {
        let f = Build20Transport { _ in .status(404) }
        defer { f.close() }
        f.defaults.set(false, forKey: LyricsSecondarySettings.enabledKey)
        let c = context()
        let saved = LyricsRecordID(providerID: .lrcapi, recordID: "saved")
        LyricsSelectionStore.select(saved, for: c.selectionKey, defaults: f.defaults)
        let repository = CompositeLyricsRepository(primary: LrcLibService(session: f.session, defaults: f.defaults),
            secondary: LrcApiService(session: f.session, defaults: f.defaults), defaults: f.defaults)
        let result = try await repository.getLyrics(context: c)
        XCTAssertNil(result)
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
        XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: f.defaults), saved)
    }

    func testSongContextCarriesAlbumIDsOriginAndVideoTypeWithoutMutatingSong() async throws {
        var song = Song(id: "video000001", title: "Original title", artistName: "Original artist", artistId: "artistID",
                        albumName: "Original album", albumId: "albumID", duration: 200, thumbnailURL: nil)
        song.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        let spy = Build20ContextSpy()
        _ = try await GetLyricsUseCase(repository: spy).execute(song: song)
        XCTAssertEqual(spy.context?.songID, song.id)
        XCTAssertEqual(spy.context?.album, song.albumName)
        XCTAssertEqual(spy.context?.artistID, song.artistId)
        XCTAssertEqual(spy.context?.albumID, song.albumId)
        XCTAssertEqual(spy.context?.musicVideoType, song.musicVideoType)
        XCTAssertEqual(spy.context?.hasYouTubeOrigin, true)
        XCTAssertEqual(song.title, "Original title")
    }

    func testMissingPerformerRequiresManualChoiceAndAmbiguousCreditsNeverGuess() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(artist: "", video: true)))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([candidate()], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertNil(LyricsCanonicalMetadata(context(artist: "", video: false)))
        XCTAssertNil(LyricsCanonicalMetadata(context(title: "A & B - Song", artist: "", video: true)))
    }

    func testPlannerAndNoResultTransportStayWithinSixMetadataRequests() async throws {
        let c = context(title: "周杰倫 - 晴天 (Official Video)", artist: "周杰倫", video: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        let queries = LyricsQueryPlanner.queries(metadata)
        XCTAssertLessThanOrEqual(queries.count, 6)
        XCTAssertTrue(queries.contains { $0.endpoint == "search" })
        XCTAssertTrue(queries.contains { $0.pair.artist == "Jay Chou" })
        let f = Build20Transport { _ in .status(404) }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertNil(result)
        XCTAssertEqual(f.requests.count, queries.count)
    }

    func testCancellationStopsFurtherQueriesAndCannotBecomeMissingLyrics() async throws {
        let f = Build20Transport { _ in .failure(.cancelled) }
        defer { f.close() }
        do {
            _ = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(f.requests.count, 1)
    }

    func testProviderNamespacesRemainDistinctForIdenticalRecordIDs() throws {
        let first = candidate(id: "1")
        let second = candidate(id: "1", provider: .lrcapi)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context()))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testVerifiedEmptyArtistUsesExtractedCreditForSecondaryRequest() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "1", "title": "Fixture song", "artist": "Fixture performer", "duration": 200,
             "lrc": "[00:01.00]Extracted credit lyric"]
        ]) }
        defer { f.close() }
        let c = context(title: "Fixture performer - Fixture song (Official Video)", artist: "", video: true)
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "Extracted credit lyric")
        XCTAssertEqual(f.requests.count, 1)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(f.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "title" }?.value, "Fixture song")
        XCTAssertEqual(query.first { $0.name == "artist" }?.value, "Fixture performer")
    }

    func testTraditionalTitleAndPerformerMatchSimplifiedCandidateWithoutChangingOriginalMetadata() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "chinese-1", "title": "后来", "artist": "刘若英", "duration": 200,
             "lrc": "[00:01.00]繁簡相同歌曲"]
        ]) }
        defer { f.close() }
        let c = context(title: "後來", artist: "劉若英")
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "繁簡相同歌曲")
        XCTAssertEqual(result?.isTimeSynced, true)
        XCTAssertEqual(c.title, "後來")
        XCTAssertEqual(c.artist, "劉若英")
    }

    func testSearchAvailabilityFailurePreservesValidPlainGetWithFailureProvenance() async throws {
        let f = Build20Transport { request in
            if request.url!.lastPathComponent == "search" { return .status(503) }
            var record = Self.primary(); record["duration"] = 230
            return .json(record)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertEqual(result?.sourceFailures.first?.providerID, .lrclib)
        XCTAssertEqual(f.requests.count, 4)
    }

    func testTemporaryGetFailureStopsSpellingVariantsAfterBoundedTransportRetry() async throws {
        let f = Build20Transport { _ in .status(503) }
        defer { f.close() }
        do {
            _ = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
            XCTFail("Temporary availability failure must remain retryable")
        } catch LyricsLookupError.unavailable(let failures) {
            XCTAssertEqual(failures.count, 1)
        }
        XCTAssertEqual(f.requests.count, 2)
        XCTAssertTrue(f.requests.allSatisfy { $0.url?.lastPathComponent == "get" })
    }

    private func context(id: String = "video000001", title: String = "Fixture song", artist: String = "Fixture performer",
                         album: String? = nil, duration: Int = 200, video: Bool = false) -> LyricsLookupContext {
        .init(songID: id, title: title, artist: artist, album: album, duration: duration, hasYouTubeOrigin: video)
    }
    private func candidate(id: String = "1", title: String = "Fixture song", artist: String = "Fixture performer",
                           duration: Double = 200, album: String? = nil, provider: LyricsProviderID = .lrclib) -> LyricsCandidate {
        .init(id: .init(providerID: provider, recordID: id), title: title, artist: artist, duration: duration,
              lyrics: SyncedLyrics(lines: [.init(time: 1, text: "Record " + id)], source: provider.displayName, providerID: provider), album: album)
    }
    private func isolatedDefaults() -> UserDefaults {
        let suite = "Build20Lyrics-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
    private static func primary() -> [String: Any] {
        ["id": 1, "trackName": "Fixture song", "artistName": "Fixture performer", "duration": 200,
         "syncedLyrics": "[00:01.00]Fixture lyric"]
    }
}

private final class Build20ContextSpy: LyricsRepositoryProtocol {
    var context: LyricsLookupContext?
    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? { self.context = context; return nil }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        XCTFail("Song lookup must retain context"); return nil
    }
}

private enum Build20Reply { case status(Int), json(Any), failure(URLError.Code) }
private final class Build20Transport {
    let session: URLSession
    let defaults: UserDefaults
    let token = UUID().uuidString
    private let suite = "Build20Transport-" + UUID().uuidString
    var requests: [URLRequest] { Build20URLProtocol.lock.withLock { Build20URLProtocol.requests[token] ?? [] } }
    init(_ handler: @escaping (URLRequest) -> Build20Reply) {
        defaults = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Build20URLProtocol.self]
        config.httpAdditionalHeaders = ["X-Build20-Fixture": token]
        session = URLSession(configuration: config)
        Build20URLProtocol.lock.withLock { Build20URLProtocol.handlers[token] = handler }
    }
    func close() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        Build20URLProtocol.lock.withLock {
            Build20URLProtocol.handlers.removeValue(forKey: token)
            Build20URLProtocol.requests.removeValue(forKey: token)
        }
    }
}
private final class Build20URLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) -> Build20Reply] = [:]
    static var requests: [String: [URLRequest]] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Build20-Fixture") ?? ""
        let handler = Self.lock.withLock { () -> ((URLRequest) -> Build20Reply)? in
            Self.requests[token, default: []].append(request)
            return Self.handlers[token]
        }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = handler(request)
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let status: Int
        let data: Data
        switch reply {
        case .status(let value): status = value; data = Data()
        case .json(let object): status = 200; data = try! JSONSerialization.data(withJSONObject: object)
        case .failure: return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
