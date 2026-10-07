import Foundation
import CryptoKit
import XCTest
@testable import LovelyMusic

/// Synthetic identity/transport regressions. These do not validate real vocals or provider availability.
final class ChineseLyricsPlanRegressionTests: XCTestCase {
    func testFixedFortyCompositionContractBeforeAnyProviderQuery() throws {
        var seen = Set<String>()
        var previous: String?
        for batch in 1...2 {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixed_lyrics_batch" + String(batch), withExtension: "json"))
            let data = try Data(contentsOf: url)
            // Git may normalize Windows CRLF on the Mac runner; song data must remain identical.
            let hashData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
            let expectedFileHash = batch == 1 ? "a1a541908b0bc0158c4c3d1f1d69cf1fbc18b1d28000bb9fad14eef3026fdd73"
                : "08f2a23b4fbce4cf7a8d446179047aa2c579cb569e90eac3c34667b04290c99b"
            XCTAssertEqual(SHA256.hash(data: hashData).map { String(format: "%02x", Int($0)) }.joined(), expectedFileHash)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(document["batch"] as? Int, batch)
            if batch == 2 { XCTAssertEqual(document["previousManifestSHA256"] as? String, previous) }
            previous = document["manifestSHA256"] as? String
            let expected = batch == 1 ? "cfb9c6e63edc670d55748676d5abdf664b726fbf6749c3edd178b258c1cf0e7a"
                : "fc933e893a1471794ae3df7281a864c946750f973d6db15b55229524e126fae5"
            XCTAssertEqual(previous, expected)
            let samples = try XCTUnwrap(document["samples"] as? [[String: Any]])
            XCTAssertEqual(samples.count, 20)
            for row in samples {
                let title = try XCTUnwrap(row["title"] as? String), artist = try XCTUnwrap(row["artist"] as? String)
                let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: title, artist: artist, hasYouTubeOrigin: true)))
                let versions = "(?i)\\s*[\\[(][^\\])]*(?:live|remix|acoustic|cover|instrumental|karaoke|demo|remaster|sped\\s*up|slowed|nightcore|現場|演唱會|翻唱)[^\\])]*[\\])]\\s*$"
                let keys = Set(metadata.hypotheses.flatMap(\.titleVariants).map {
                    LyricsLookupMetadata.identityKey($0.replacingOccurrences(of: versions, with: "", options: .regularExpression))
                }.filter { !$0.isEmpty })
                XCTAssertFalse(keys.isEmpty)
                XCTAssertTrue(keys.isDisjoint(with: seen), "Fixed sample overlaps after integrated metadata projections: " + title)
                seen.formUnion(keys)
            }
        }
    }

    private func candidate(_ title: String, _ artist: String, duration: Double? = 200,
                           id: String = "record", synced: Bool = true) -> LyricsCandidate {
        let lyrics = LyricsMatchingPolicy.lyrics(syncedLRC: synced ? "[00:01.00]Synthetic line" : "",
            plainText: "Synthetic line", recordingDuration: duration, videoDuration: 200, provider: .lrclib)!
        return .init(id: .init(providerID: .lrclib, recordID: id), title: title, artist: artist,
                     duration: duration, lyrics: lyrics)
    }

    func testCompactDashAndPromoLabelsKeepBothUncertainRolesAndOriginalFields() throws {
        let title = "[JOY RICH] [新歌] 陳思函-雨不停(台劇飯糰之家片尾曲)(完整發行版)"
        let context = LyricsLookupContext(songID: "fixed-video", title: title, artist: "Channel", duration: 200,
                                         hasYouTubeOrigin: true, artistNameSource: .uploader)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(metadata.pair.title, "雨不停")
        XCTAssertEqual(metadata.pair.artist, "陳思函")
        XCTAssertTrue(metadata.presentationContext.contains("飯糰之家"))
        XCTAssertEqual(LyricsLookupMetadata.videoCreditPairs(context).count, 2)
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        XCTAssertEqual(context.title, title); XCTAssertEqual(context.artist, "Channel")
        XCTAssertEqual(context.artistNameSource, .uploader)
        XCTAssertEqual(context.selectionKey, "song:fixed-video")
        XCTAssertNil(LyricsCanonicalMetadata(.init(title: "[新歌]", artist: "", hasYouTubeOrigin: true)))
    }

    func testSingleCharacterRainPerformerDifferenceStaysManualAndIsNotAnAlias() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "雨不停", artist: "陳思函", duration: 200)))
        let result = LyricsCandidateScorer.decision(candidate("雨不停", "陈思涵"), metadata: metadata)
        XCTAssertEqual(result.kind, .relatedManual)
        XCTAssertEqual(result.reason, .artistSpellingUncertain)
        XCTAssertEqual(result.scoreBreakdown["artist"], 10)
        XCTAssertLessThan(result.score, 85)
        XCTAssertNotEqual(LyricsCanonicalMetadata.artistIdentity(LyricsLookupMetadata.identityKey("陳思函")),
                          LyricsCanonicalMetadata.artistIdentity(LyricsLookupMetadata.identityKey("陈思涵")))
    }

    func testWrongPerformerCannotBeRescuedByDurationOrRememberedID() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "雨不停", artist: "陳思函", duration: 200)))
        let wrong = candidate("雨不停", "周杰倫")
        XCTAssertEqual(LyricsCandidateScorer.decision(wrong, metadata: metadata, remembered: wrong.id).kind, .rejected)
    }

    func testUnknownDurationDoesNotReceiveFixedBonusAndMappingsKeepProviderNamespace() throws {
        let context = LyricsLookupContext(songID: "fixed", title: "Song", artist: "Singer")
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        let record = candidate("Song", "Singer", duration: nil)
        let result = LyricsCandidateScorer.decision(record, metadata: metadata)
        XCTAssertEqual(result.scoreBreakdown["duration"], 0)
        XCTAssertEqual(result.score, 75); XCTAssertEqual(result.kind, .relatedManual)
        let suite = "ChinesePlanNamespace-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let saved = LyricsRecordID(providerID: .lrcapi, recordID: "123")
        LyricsSelectionStore.select(saved, for: context.selectionKey, defaults: defaults)
        XCTAssertEqual(LyricsCandidateScorer.remembered(context, defaults: defaults), saved)
        XCTAssertNotEqual(saved, LyricsRecordID(providerID: .lrclib, recordID: "123"))
        let chinese = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "雨不停", artist: "陳思函", album: "")))
        let raw = candidate("雨不停", "陳思函", duration: nil)
        let emptyAlbum = LyricsCandidate(id: raw.id, title: raw.title, artist: raw.artist, duration: nil, lyrics: raw.lyrics, album: "")
        let emptyAlbumDecision = LyricsCandidateScorer.decision(emptyAlbum, metadata: chinese)
        XCTAssertEqual(emptyAlbumDecision.scoreBreakdown["weakContext"], 0)
        XCTAssertEqual(emptyAlbumDecision.score, 80)
        XCTAssertEqual(emptyAlbumDecision.kind, .relatedManual)
    }

    func testRememberedUntimedRecordContinuesFallback() async throws {
        let suite = "ChinesePlanUntimed-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChinesePlanProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let context = LyricsLookupContext(songID: "fixed", title: "Song", artist: "Singer", duration: 200)
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "124"), for: context.selectionKey, defaults: defaults)
        ChinesePlanProtocol.clear()
        LyricsLookupDiagnostics.shared.clear()
        let report = try await LrcLibService(session: session, defaults: defaults).lookup(context: context)
        XCTAssertTrue(ChinesePlanProtocol.paths.contains { $0.hasSuffix("/search") })
        XCTAssertTrue(report.providers.flatMap(\.evaluatedCandidates).contains { $0.recordID == "124" && $0.timing == "plainOnly" })
        XCTAssertFalse(report.lyrics?.isTimeSynced ?? true)
        XCTAssertFalse(LyricsLookupDiagnostics.shared.events.contains { $0.recordID == "124" && $0.phase == .candidateDropped })
    }

    func testVersionWordsRemainAndWrongVersionIsRejected() throws {
        for version in ["Live", "Remix", "Acoustic", "Cover", "Instrumental", "Karaoke", "Demo", "Remastered",
                        "Sped Up", "Slowed", "Nightcore", "Radio Edit", "Extended", "Original Mix", "現場", "伴奏"] {
            let source = "陳思函-雨不停 (" + version + ") (歌詞版)"
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: source, artist: "陳思函", duration: 200,
                                                                       hasYouTubeOrigin: true)))
            XCTAssertTrue(metadata.pair.title.contains(version), source)
            XCTAssertEqual(LyricsCandidateScorer.decision(candidate("雨不停", "陳思函"), metadata: metadata).kind, .rejected, source)
        }
        let formal = "雨不停 (Live Official MV)"
        XCTAssertTrue(ChineseLyricsMetadataCleaner.preparedTitle(formal).contains("Live"))
        XCTAssertEqual(ChineseLyricsMetadataCleaner.preparedTitle("[Unknown] Formal Title"), "[Unknown] Formal Title")
    }

    func testTrailingFeatCreditAndLabelAreRetainedAsCompletePerformerSet() throws {
        for source in ["Illenium - U & Me (Lyrics) ft. Sasha Sloan", "Illenium - U & Me (feat. Sasha Sloan)"] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: source, artist: "", duration: 200,
                                                                       hasYouTubeOrigin: true)))
            XCTAssertEqual(metadata.pair.title, "U & Me")
            XCTAssertEqual(LyricsCanonicalMetadata.tokens(metadata.pair.artist), ["illenium", "sashasloan"])
            XCTAssertEqual(LyricsCandidateScorer.decision(candidate("U & Me", "Other feat. Sasha Sloan"), metadata: metadata).kind, .rejected)
        }
    }

    func testMalformedFeatureBracketsDoNotCreateCreditsOrCandidateAliases() throws {
        for suffix in ["(feat. Guest", "[feat. Guest", "(feat. Guest]", "[feat. Guest)"] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Singer - Song " + suffix,
                artist: "Singer", duration: 200, hasYouTubeOrigin: true)))
            XCTAssertEqual(metadata.pair.artist, "Singer")
            XCTAssertTrue(metadata.pair.title.contains(suffix))
        }
        let source = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer feat. Guest", duration: 200)))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song (feat. Guest]", "Singer"), metadata: source).kind, .rejected)
    }

    func testCompleteCollaborationSetsAndOrderedPrimaryAreRequired() throws {
        let duet = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer & Guest", duration: 200)))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song", "Guest & Singer"), metadata: duet).kind, .confirmed)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song", "Singer & Guest & Other"), metadata: duet).kind, .rejected)
        let feature = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer feat. Guest", duration: 200)))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song", "Guest feat. Singer"), metadata: feature).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song", "Singer"), metadata: feature).kind, .relatedManual)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song", "Guest"), metadata: feature).kind, .rejected)
    }

    func testBelowThresholdEvidenceRetainsActualFieldScores() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "", duration: 200, hasYouTubeOrigin: true)))
        let result = LyricsCandidateScorer.decision(candidate("Song", "Singer"), metadata: metadata)
        XCTAssertEqual(result.kind, .rejected); XCTAssertEqual(result.reason, .scoreBelowManual)
        XCTAssertEqual(result.score, 60)
        XCTAssertEqual(result.scoreBreakdown["title"], 40)
        XCTAssertEqual(result.scoreBreakdown["artist"], 0)
        XCTAssertEqual(result.scoreBreakdown["duration"], 20)
    }

    func testRevertUsesSharedTitleVariantsAndExclusiveFieldScores() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(
            title: "郁可唯 Yisa Yu【倒流 Revert】三立華劇《浮士德的微笑》插曲 Official Lyric Video",
            artist: "", duration: 254, hasYouTubeOrigin: true)))
        XCTAssertEqual(metadata.explicitTitleVariants, ["倒流 Revert", "倒流", "Revert"])
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).contains { $0.pair.title == "倒流" && $0.pair.artist == "郁可唯" })
        XCTAssertTrue(LyricsQueryPlanner.secondaryPairs(metadata).contains { $0.title == "倒流" && $0.artist == "郁可唯" })
        XCTAssertLessThanOrEqual(LyricsQueryPlanner.queries(metadata).count, 6)
        let record = candidate("倒流", "郁可唯", duration: 253.067, id: "1185835188")
        let result = LyricsCandidateScorer.decision(record, metadata: metadata)
        XCTAssertEqual(result.kind, .confirmed)
        XCTAssertEqual(result.scoreBreakdown["title"], 45)
        XCTAssertEqual(result.scoreBreakdown["artist"], 35)
        XCTAssertEqual(result.scoreBreakdown["duration"], 20)
        XCTAssertEqual(result.score, result.scoreBreakdown.values.reduce(0, +))
    }

    func testDurationPointsHaveBoundariesAndUnknownDurationGetsNoBonus() {
        for (duration, points) in [(202.0, 20), (202.001, 15), (205, 15), (205.001, 8), (210, 8), (210.001, 0)] {
            XCTAssertEqual(LyricsIdentityPolicy.durationPoints(recording: duration, video: 200), points)
        }
        for duration in [Double.nan, Double.infinity, -1, 0, 86401] {
            XCTAssertEqual(LyricsIdentityPolicy.durationPoints(recording: duration, video: 200), 0)
        }
        XCTAssertEqual(LyricsIdentityPolicy.durationPoints(recording: nil, video: 200), 0)
        XCTAssertEqual(LyricsIdentityPolicy.durationPoints(recording: 200, video: nil), 0)
    }

    func testRejectedEvidencePreservesIdentityWithoutLyricText() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let wrong = candidate("Song", "Other", id: "rejected")
        let evidence = LyricsCandidateEvidence(provider: .lrclib, recordID: wrong.recordID, title: wrong.title,
            artist: wrong.artist, album: nil, duration: wrong.duration, metadata: metadata, candidate: wrong)
        let encoded = try JSONEncoder().encode(evidence)
        let decoded = try JSONDecoder().decode(LyricsCandidateEvidence.self, from: encoded)
        XCTAssertEqual(decoded.recordID, "rejected"); XCTAssertEqual(decoded.artist, "Other")
        XCTAssertEqual(decoded.identity, "rejected"); XCTAssertEqual(decoded.actualVocalAlignment, "NOT_RUN")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Synthetic line"))
        let content = candidate("Song", "Singer", id: "unexpected-endpoint-id")
        let unexpected = LyricsCandidateEvidence(provider: .lrclib, recordID: content.recordID, title: content.title,
            artist: content.artist, album: nil, duration: content.duration, metadata: metadata, candidate: content,
            discardedReason: .identityMismatch)
        XCTAssertEqual(unexpected.identity, "rejected")
        XCTAssertEqual(unexpected.contentLineCount, 1)
        XCTAssertEqual(unexpected.timing, "structurallyCompatible")
        let reverse = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song - Singer", artist: "", duration: 200, hasYouTubeOrigin: true)))
        let reverseEvidence = LyricsCandidateEvidence(provider: .lrclib, recordID: content.recordID, title: content.title,
            artist: content.artist, album: nil, duration: content.duration, metadata: reverse, candidate: content)
        XCTAssertEqual(reverseEvidence.canonicalTitle, "Song"); XCTAssertEqual(reverseEvidence.canonicalArtist, "Singer")
    }

    func testRememberedWrongIdentityFallsBackAndLegacyLrcApiUsesCommonScorer() async throws {
        let suite = "ChineseLyricsPlan-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChinesePlanProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let context = LyricsLookupContext(songID: "fixed", title: "Song", artist: "Singer", duration: 200)
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "123"), for: context.selectionKey, defaults: defaults)
        ChinesePlanProtocol.clear()
        let report = try await LrcLibService(session: session, defaults: defaults).lookup(context: context)
        XCTAssertTrue(ChinesePlanProtocol.paths.contains { $0.hasSuffix("/search") })
        XCTAssertEqual(report.lyrics?.candidates.first?.recordID, "456")
        XCTAssertTrue(report.providers.flatMap(\.evaluatedCandidates).contains { $0.recordID == "123" && $0.identity == "rejected" })
        XCTAssertTrue(report.providers.flatMap(\.evaluatedCandidates).contains { $0.recordID == "456" && $0.identity == "confirmed" })
        XCTAssertTrue(report.providers.allSatisfy { $0.evaluatedCandidates.count == $0.receivedCount })
        XCTAssertTrue(report.providers.flatMap(\.evaluatedCandidates).allSatisfy { $0.queryEndpoint != nil })
        let legacy = try await LrcApiService(session: session, defaults: defaults).getLyrics(title: "Song", artist: "Singer", duration: 200)
        XCTAssertEqual(legacy?.candidates.first?.identityDecision?.kind, .confirmed)
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "125"), for: context.selectionKey, defaults: defaults)
        let wrongEndpoint = try await LrcLibService(session: session, defaults: defaults).lookup(context: context)
        XCTAssertTrue(wrongEndpoint.providers.flatMap(\.evaluatedCandidates).contains {
            $0.recordID == "126" && $0.identity == "rejected" && $0.contentLineCount == 1
        })
        XCTAssertTrue(wrongEndpoint.providers.allSatisfy {
            $0.contentCandidateCount == $0.evaluatedCandidates.filter { $0.contentLineCount > 0 }.count
        })
        XCTAssertFalse(wrongEndpoint.lyrics?.candidates.contains { $0.recordID == "126" } ?? true)
    }
}

private final class ChinesePlanProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [String] = []
    static var paths: [String] { lock.withLock { recorded } }
    static func clear() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recorded.append(url.path) }
        let body: String
        let status: Int
        if url.path.hasSuffix("/get/123") {
            status = 200
            body = #"{"id":123,"trackName":"Song","artistName":"Wrong","duration":200,"syncedLyrics":"[00:01.00]Synthetic line"}"#
        } else if url.path.hasSuffix("/get/124") {
            status = 200
            body = #"{"id":124,"trackName":"Song","artistName":"Singer","duration":200,"plainLyrics":"Synthetic plain line"}"#
        } else if url.path.hasSuffix("/get/125") {
            status = 200
            body = #"{"id":126,"trackName":"Song","artistName":"Singer","duration":200,"syncedLyrics":"[00:01.00]Synthetic line"}"#
        } else if url.path.hasSuffix("/search") {
            status = 200
            body = #"[{"id":456,"trackName":"Song","artistName":"Singer","duration":200,"syncedLyrics":"[00:01.00]Synthetic line"}]"#
        } else if url.path.hasSuffix("/jsonapi") {
            status = 200
            body = #"[{"id":"secondary","title":"Song","artist":"Singer","duration":200,"lrc":"[00:01.00]Synthetic line"}]"#
        } else { status = 404; body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
