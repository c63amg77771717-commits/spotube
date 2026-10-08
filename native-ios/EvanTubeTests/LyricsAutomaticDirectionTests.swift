import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsAutomaticDirectionTests: XCTestCase {
    private func withRepository(_ mode: String, title: String = "Performer - Track (Lyrics) ft. Guest",
                                artist: String = "", source: SongArtistNameSource? = nil,
                                body: (LrcLibService, LyricsLookupContext, UserDefaults) async throws -> Void) async throws {
        DirectionHTTPFixture.configure(mode)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectionHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let name = "DirectionRegression." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let context = LyricsLookupContext(songID: "synVideo001", title: title, artist: artist,
            duration: mode == "real-metadata" ? 214 : 200, hasYouTubeOrigin: true, artistNameSource: source)
        try await body(LrcLibService(session: session, defaults: defaults), context, defaults)
    }

    // Existing public API: baseline stays manual despite 95 raw points and
    // successful forward + reverse metadata searches. No live HTTP occurs here.
    func testCapturedUAndMeMetadataCanResolveDirectionWithoutSongSpecificCode() async throws {
        try await withRepository("real-metadata", title: "Illenium - U & Me (Lyrics) ft. Sasha Sloan") { service, context, _ in
            let report = try await service.lookup(context: context)
            XCTAssertEqual(report.state, .synchronized)
            XCTAssertEqual(report.lyrics?.candidates.first?.identityDecision?.score, 95)
            XCTAssertEqual(report.lyrics?.candidates.first?.identityDecision?.kind, .confirmed)
            XCTAssertTrue(DirectionHTTPFixture.titles.contains("Illenium"), "Reverse direction must actually finish")
        }
    }

    func testGenericCaptionDirectionCanResolveAfterBothSearches() async throws {
        try await withRepository("forward") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .synchronized)
            XCTAssertTrue(DirectionHTTPFixture.titles.contains("Performer"))
        }
    }

    func testTwoSupportedDirectionsStayManual() async throws {
        try await withRepository("both") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .manualSelection)
        }
    }

    func testMissingFeaturedArtistCannotBePromoted() async throws {
        try await withRepository("missing-guest") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertNotEqual(result.state, .synchronized)
            XCTAssertFalse(result.lyrics?.candidates.contains { $0.identityDecision?.kind == .confirmed } ?? false)
        }
    }

    func testWrongVersionStaysRejected() async throws {
        try await withRepository("live") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .candidatesRejected)
        }
    }

    func testUploaderBylineIsNotARecordingArtist() async throws {
        try await withRepository("forward", title: "Track", artist: "Performer feat. Guest", source: .uploader) { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertNotEqual(result.state, .synchronized)
        }
    }

    func testSuppliedArtistContradictionCannotUseCaptionOverride() async throws {
        try await withRepository("forward", artist: "Other performer", source: .artistMetadata) { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertNotEqual(result.state, .synchronized)
        }
    }

    func testReverseTimeoutIsNotNegativeDirectionEvidence() async throws {
        try await withRepository("reverse-timeout") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .manualSelection)
            XCTAssertFalse(result.failures.isEmpty)
        }
    }

    func testTruncatedReverseResponseIsNotNegativeEvidence() async throws {
        try await withRepository("reverse-truncated") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .manualSelection)
        }
    }

    func testConfirmedDirectionStillKeepsTwoCompetingRecordingsManual() async throws {
        try await withRepository("two-recordings") { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .manualSelection)
            XCTAssertEqual(result.lyrics?.candidates.filter { $0.identityDecision?.kind == .confirmed }.count, 2)
        }
    }

    func testCancellationCannotBecomeDirectionConfirmation() async throws {
        try await withRepository("forward") { service, context, _ in
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await service.lookup(context: context)
            }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancellation must propagate") }
            catch is CancellationError { }
        }
    }

    func testExplicitArtistKeepsOneRequestFastPath() async throws {
        try await withRepository("fast", title: "Track", artist: "Performer feat. Guest", source: .artistMetadata) { service, context, _ in
            let result = try await service.lookup(context: context)
            XCTAssertEqual(result.state, .synchronized)
            XCTAssertEqual(DirectionHTTPFixture.titles.count, 1)
        }
    }

    private func syntheticMetadata(artist: String = "", source: SongArtistNameSource? = nil) throws -> LyricsCanonicalMetadata {
        try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Performer - Track (Lyrics) ft. Guest",
            artist: artist, duration: 200, hasYouTubeOrigin: true, artistNameSource: source)))
    }
    private func syntheticCandidate(_ id: String = "one", title: String = "Track", artist: String = "Performer feat. Guest",
                                    provider: LyricsProviderID = .lrclib) -> LyricsCandidate {
        .init(id: .init(providerID: provider, recordID: id), title: title, artist: artist, duration: 200,
            lyrics: .init(lines: [.init(time: 1, text: "Synthetic line"), .init(time: 2, text: "Another line")],
                          source: "Synthetic fixture"), album: "Synthetic Album")
    }
    private func completeCoverage(_ metadata: LyricsCanonicalMetadata) -> LyricsDirectionCoverage {
        var coverage = LyricsDirectionCoverage()
        for pair in LyricsDirectionPolicy.requiredPairs(metadata) { coverage.recordSuccess(pair, recordCount: 0) }
        return coverage
    }

    func testUnattemptedOrBudgetOmittedDirectionCannotConfirm() throws {
        let metadata = try syntheticMetadata()
        let pairs = LyricsDirectionPolicy.requiredPairs(metadata)
        XCTAssertGreaterThanOrEqual(pairs.count, 2)
        var partial = LyricsDirectionCoverage()
        partial.recordSuccess(pairs[0], recordCount: 1)
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate()], metadata: metadata, coverage: [partial]).isEmpty)
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate()], metadata: metadata, coverage: []).isEmpty)
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate()], metadata: metadata,
            coverage: [completeCoverage(metadata), .unavailable]).isEmpty)
    }

    func testMalformedDirectionResponseCannotConfirm() throws {
        let metadata = try syntheticMetadata()
        var coverage = completeCoverage(metadata)
        coverage.recordSuccess(LyricsDirectionPolicy.requiredPairs(metadata)[0], recordCount: 1, metadataComplete: false)
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate()], metadata: metadata, coverage: [coverage]).isEmpty)
    }

    func testPlannerBudgetCannotTurnAnUnqueriedRetainedTitleIntoNegativeEvidence() throws {
        let context = LyricsLookupContext(title: "甲乙 Artist - 甲歌 Track『這是一段足夠長的歌詞示例片段，不能擅自認成歌曲別名』【動態歌詞】",
            artist: "", duration: 200, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        let required = LyricsDirectionPolicy.requiredPairs(metadata)
        let planned = LyricsQueryPlanner.queries(metadata)
        XCTAssertGreaterThan(required.count, planned.count)
        XCTAssertLessThanOrEqual(planned.count, 6)
        var coverage = LyricsDirectionCoverage()
        for query in planned where query.endpoint == "search" { coverage.recordSuccess(query.pair, recordCount: 0) }
        XCTAssertFalse(coverage.covers(required))
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate(title: "甲歌", artist: "甲乙")],
            metadata: metadata, coverage: [coverage]).isEmpty)
    }

    func testWrongMainGuestOrderCannotResolveDirection() throws {
        let metadata = try syntheticMetadata()
        XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs(
            [syntheticCandidate(artist: "Guest feat. Performer")], metadata: metadata, coverage: [completeCoverage(metadata)]).isEmpty)
    }

    func testCoverageCannotPromoteAnIncompleteRoleCandidateAlongsideACompleteOne() throws {
        let metadata = try syntheticMetadata()
        let ids = LyricsDirectionPolicy.confirmedHypothesisIDs([syntheticCandidate()], metadata: metadata, coverage: [completeCoverage(metadata)])
        XCTAssertFalse(ids.isEmpty)
        let unordered = LyricsIdentityPolicy.decision(syntheticCandidate(artist: "Performer & Guest"), metadata: metadata, confirmedDirectionIDs: ids)
        XCTAssertEqual(unordered.kind, .relatedManual)
    }

    func testCoverageIsNotBorrowedFromBaselineScoringCache() throws {
        let metadata = try syntheticMetadata()
        let suite = "DirectionCache." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LyricsLookupScoringSession()
        let candidates = [syntheticCandidate()]
        let before = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, scoringSession: session)
        let after = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, scoringSession: session,
            directionCoverage: [completeCoverage(metadata)])
        let againWithout = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, scoringSession: session)
        XCTAssertTrue(before?.lines.isEmpty ?? false)
        XCTAssertFalse(after?.lines.isEmpty ?? true)
        XCTAssertTrue(againWithout?.lines.isEmpty ?? false)
    }

    func testCompositeReadsEnabledSecondaryBeforeAcceptingCaptionDirection() async throws {
        let metadata = try syntheticMetadata()
        let candidates = [syntheticCandidate()]
        let suite = "DirectionComposite." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coverage = completeCoverage(metadata)
        let selected = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, directionCoverage: [coverage])
        var first = LyricsLookupReport.provider(.lrclib, lyrics: selected, received: 1, successfulResponses: 2, failures: [])
        first.directionEvidence = .init(candidates: candidates, coverage: [coverage])
        let reverse = syntheticCandidate("reverse", title: "Performer", artist: "Track feat. Guest", provider: .lrcapi)
        var second = LyricsLookupReport.provider(.lrcapi, lyrics: nil, received: 1, successfulResponses: 2, failures: [])
        second.directionEvidence = .init(candidates: [reverse], coverage: [coverage])
        let secondary = DirectionReportFixture(second)
        let composite = CompositeLyricsRepository(primary: DirectionReportFixture(first), secondary: secondary,
            defaults: defaults, secondaryEnabled: { true })
        let report = try await composite.lookup(context: metadata.context)
        XCTAssertEqual(secondary.calls, 1)
        XCTAssertEqual(report.state, .manualSelection)
    }

    func testCompositeSecondaryFailureCannotBeNegativeEvidence() async throws {
        let metadata = try syntheticMetadata()
        let candidates = [syntheticCandidate()]
        let suite = "DirectionCompositeFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coverage = completeCoverage(metadata)
        let selected = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, directionCoverage: [coverage])
        var first = LyricsLookupReport.provider(.lrclib, lyrics: selected, received: 1, successfulResponses: 2, failures: [])
        first.directionEvidence = .init(candidates: candidates, coverage: [coverage])
        let second = LyricsLookupReport.provider(.lrcapi, lyrics: nil, received: 0, successfulResponses: 0,
            failures: [.init(providerID: .lrcapi, message: "Synthetic timeout", reason: .network)])
        let composite = CompositeLyricsRepository(primary: DirectionReportFixture(first), secondary: DirectionReportFixture(second),
            defaults: defaults, secondaryEnabled: { true })
        let report = try await composite.lookup(context: metadata.context)
        XCTAssertEqual(report.state, .manualSelection)
    }

    func testCompositeExplicitIdentityRetainsSecondarySkipFastPath() async throws {
        let candidate = syntheticCandidate()
        let first = LyricsLookupReport.provider(.lrclib, lyrics: candidate.lyrics, received: 1, successfulResponses: 1, failures: [])
        let secondary = DirectionReportFixture(.provider(.lrcapi, lyrics: nil, received: 0, successfulResponses: 1, failures: []))
        let composite = CompositeLyricsRepository(primary: DirectionReportFixture(first), secondary: secondary, secondaryEnabled: { true })
        let report = try await composite.lookup(context: .init(title: "Track", artist: "Performer feat. Guest", duration: 200))
        XCTAssertEqual(report.state, .synchronized)
        XCTAssertEqual(secondary.calls, 0)
    }

    func testCompositeLegacyContentCannotBypassMissingDirectionCoverage() async throws {
        let metadata = try syntheticMetadata()
        let first = LyricsLookupReport.provider(.lrclib, lyrics: syntheticCandidate().lyrics,
            received: 1, successfulResponses: 1, failures: [])
        let second = LyricsLookupReport.provider(.lrcapi, lyrics: nil, received: 0, successfulResponses: 0,
            failures: [.init(providerID: .lrcapi, message: "Synthetic timeout", reason: .network)])
        let composite = CompositeLyricsRepository(primary: DirectionReportFixture(first), secondary: DirectionReportFixture(second),
            secondaryEnabled: { true })
        let report = try await composite.lookup(context: metadata.context)
        XCTAssertNil(report.lyrics)
    }

    func testCompleteArtistRunsPreserveCollaboratorAndExcludeAlbum() throws {
        func artistRun(_ name: String, _ id: String) -> [String: Any] {
            ["text": name, "navigationEndpoint": ["browseEndpoint": ["browseId": id,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]]]]]
        }
        let objects: [[String: Any]] = [artistRun("Performer", "artist-one"), ["text": " & "],
            artistRun("Guest", "artist-two"), ["text": " • "], ["text": "Synthetic Album"]]
        let runs = try JSONDecoder().decode([Run].self, from: JSONSerialization.data(withJSONObject: objects))
        let credit = MusicArtistCreditMapper.map(runs)
        XCTAssertEqual(credit.name, "Performer, Guest")
        XCTAssertEqual(credit.source, .artistMetadata)
        let unknown = MusicArtistCreditMapper.map([Run(text: "Uploader", navigationEndpoint: nil)])
        XCTAssertEqual(unknown.source, .unknown)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Track", artist: "Uploader", duration: 200,
            hasYouTubeOrigin: true, artistNameSource: unknown.source)))
        XCTAssertEqual(metadata.originalArtist, "")
    }

    func testOnlineResolverPreservesUploaderProvenanceWhenCatalogArtistIsAbsent() async throws {
        let item = EvanTubeOnlineItem(id: "synthetic", title: "Track", artist: "", artworkURL: nil, kind: .song, releaseDate: nil)
        let song = Song(id: "synVideo001", title: "Track", artistName: "Uploader", artistId: nil, albumName: nil,
            albumId: nil, duration: 200, thumbnailURL: nil, artistNameSource: .uploader)
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { _ in [song] }
        XCTAssertEqual(resolved?.artistNameSource, .uploader)
    }

    private func musicRuns() -> [[String: Any]] {
        func artist(_ name: String, _ id: String) -> [String: Any] {
            ["text": name, "navigationEndpoint": ["browseEndpoint": ["browseId": id,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]]]]]
        }
        return [artist("Performer", "artist-one"), ["text": " & "], artist("Guest", "artist-two"),
                ["text": " • "], ["text": "Synthetic Album"]]
    }

    func testSearchMapperRetainsFullArtistGroupAndProvenance() throws {
        let object: [String: Any] = ["flexColumns": [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Track"]]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": musicRuns()]]]
        ], "playlistItemData": ["videoId": "synVideo001"]]
        let renderer = try JSONDecoder().decode(MusicResponsiveListItemRenderer.self,
            from: JSONSerialization.data(withJSONObject: object))
        let song = try XCTUnwrap(SearchResponseMapper.mapSong(from: renderer))
        XCTAssertEqual(song.artistName, "Performer, Guest")
        XCTAssertEqual(song.artistNameSource, .artistMetadata)
        XCTAssertEqual(song.title, "Track")
    }

    func testNextMapperRetainsLongBylineCollaboratorInsteadOfShortBylineOnly() throws {
        let row: [String: Any] = ["playlistPanelVideoRenderer": ["title": ["runs": [["text": "Track"]]],
            "videoId": "synVideo001", "longBylineText": ["runs": musicRuns()],
            "shortBylineText": ["runs": [["text": "Performer"]]], "lengthText": ["runs": [["text": "3:20"]]]]]
        let object: [String: Any] = ["contents": ["singleColumnMusicWatchNextResultsRenderer": [
            "tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [["tabRenderer": ["content": [
                "musicQueueRenderer": ["content": ["playlistPanelRenderer": ["contents": [row]]]]]]]]]]]]]
        let song = try XCTUnwrap(NextResponseMapper.map(JSONSerialization.data(withJSONObject: object)).first)
        XCTAssertEqual(song.artistName, "Performer, Guest")
        XCTAssertEqual(song.artistNameSource, .artistMetadata)
        XCTAssertEqual(song.duration, 200)
    }

    func testUnknownBylineProvenanceSurvivesSongPersistence() throws {
        let song = Song(id: "synVideo001", title: "Track", artistName: "Unclassified byline", artistId: nil,
            albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil, artistNameSource: .unknown)
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored.artistNameSource, .unknown)
        XCTAssertEqual(restored.artistName, song.artistName)
        XCTAssertEqual(try XCTUnwrap(LyricsCanonicalMetadata(LyricsLookupContext(song: restored))).originalArtist, "")
    }

    func testFixedFortyWithoutCapturedQueryCompletionCannotBePromoted() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "saved_40_candidate_identity_metadata", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let samples = try XCTUnwrap(document["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 40)
        XCTAssertEqual(document["providerTextAndTimelineStored"] as? Bool, false)
        let suite = "DirectionFixedForty." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var modes: [String: Int] = [:]
        var rows: [[String: Any]] = []
        for sample in samples {
            let title = try XCTUnwrap(sample["title"] as? String)
            let artist = try XCTUnwrap(sample["artist"] as? String)
            let context = LyricsLookupContext(title: title, artist: artist, duration: sample["duration"] as? Int,
                hasYouTubeOrigin: true, includeDurationInQuery: false)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let records = try XCTUnwrap(sample["candidates"] as? [[String: Any]])
            let candidates = records.compactMap { record -> LyricsCandidate? in
                guard let raw = record["provider"] as? String, let provider = LyricsProviderID(rawValue: raw),
                      let id = record["recordID"] as? String, let track = record["title"] as? String,
                      let performer = record["artist"] as? String else { return nil }
                let present = (record["contentLineCount"] as? Int ?? 0) > 0
                let lines: [LyricLine] = present ? [.init(time: 0, text: "Synthetic content-presence marker; actual text/timeline NOT_CAPTURED")] : []
                let timing = LyricsTimingState(rawValue: record["timing"] as? String ?? "plainOnly") ?? .plainOnly
                return .init(id: .init(providerID: provider, recordID: id), title: track, artist: performer,
                    duration: (record["duration"] as? NSNumber)?.doubleValue,
                    lyrics: .init(lines: lines, source: provider.displayName, isTimeSynced: false,
                                  providerID: provider, timingState: timing), album: record["album"] as? String)
            }
            XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs(candidates, metadata: metadata, coverage: []).isEmpty)
            let selected = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, directionCoverage: [])
            let mode = selected == nil ? "rejected" : selected!.lines.isEmpty ? "manual" : "automatic"
            XCTAssertEqual(mode, sample["expectedIdentityOnlyMode"] as? String)
            XCTAssertTrue(LyricsRecordingEvidence.groups(selected?.candidates ?? []).isEmpty)
            modes[mode, default: 0] += 1
            rows.append(["batch": sample["batch"] as? Int ?? 0, "sampleKey": sample["sampleKey"] as? String ?? "",
                         "mode": mode, "directionQueryCompletion": "NOT_CAPTURED"])
        }
        XCTAssertEqual(modes, ["manual": 25, "rejected": 15])
        let result: [String: Any] = ["samples": 40, "selectionModes": modes, "rows": rows, "networkRequests": 0,
            "syntheticContentPresenceMarkersOnly": true, "queryCompletionEvidence": "NOT_CAPTURED",
            "recordingTextTimelineEquivalence": "NOT_RUN", "physicalDevice": false, "actualVocalAlignment": "NOT_RUN"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-direction-fixed40-no-invented-coverage"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class DirectionReportFixture: LyricsRepositoryProtocol {
    let report: LyricsLookupReport
    private(set) var calls = 0
    init(_ report: LyricsLookupReport) { self.report = report }
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport { calls += 1; return report }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { report.lyrics }
}

private final class DirectionHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var mode = "forward"
    private static var observedTitles: [String] = []
    static func configure(_ value: String) { lock.withLock { mode = value; observedTitles = [] } }
    static var titles: [String] { lock.withLock { observedTitles } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "lrclib.net", ["search", "get"].contains(url.lastPathComponent) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let title = components.queryItems?.first { $0.name == "track_name" }?.value ?? ""
        let mode = Self.lock.withLock { Self.observedTitles.append(title); return Self.mode }
        let forward = title == "Track" || title == "U & Me"
        let reverse = title == "Performer" || title == "Illenium"
        if mode == "reverse-timeout", reverse {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        func record(_ id: Int, title: String, artist: String, text: String = "Synthetic line", duration: Int = 200) -> [String: Any] {
            ["id": id, "trackName": title, "artistName": artist, "albumName": "Synthetic Album", "duration": duration,
             "syncedLyrics": "[00:01.00]" + text + "\n[00:02.00]Second synthetic line"]
        }
        if url.lastPathComponent == "get" {
            let response = HTTPURLResponse(url: url, statusCode: mode == "fast" ? 200 : 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body: Any = mode == "fast" ? record(1, title: "Track", artist: "Performer feat. Guest") : [:]
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self); return
        }
        var records: [[String: Any]] = []
        if forward {
            records = [mode == "real-metadata"
                ? record(2591254, title: "U & Me", artist: "ILLENIUM feat. Sasha Sloan", duration: 214)
                : record(1, title: mode == "live" ? "Track (Live)" : "Track",
                         artist: mode == "missing-guest" ? "Performer" : "Performer feat. Guest")]
            if mode == "two-recordings" { records.append(record(2, title: "Track", artist: "Performer feat. Guest", text: "Different complete text")) }
        } else if reverse, mode == "both" {
            records = [record(3, title: "Performer", artist: "Track feat. Guest")]
        } else if reverse, mode == "reverse-truncated" {
            records = (0..<31).map { record(100 + $0, title: "Unrelated", artist: "Unrelated") }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: records))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
