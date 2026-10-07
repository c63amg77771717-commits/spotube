import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsDeviceLabelAndLatencyTests: XCTestCase {
    func testSameFixtureScoringBeforeAndAfterHypothesisPreparation() throws {
        let context = LyricsLookupContext(title: "範例歌手 - 測試歌曲『一句示範短句』【動態歌詞/Vietsub/Pinyin Lyrics】",
            artist: "", duration: 214, hasYouTubeOrigin: true)
        let uncached = try XCTUnwrap(LyricsCanonicalMetadata(context, cacheHypotheses: false))
        let cached = try XCTUnwrap(LyricsCanonicalMetadata(context))
        func candidate(_ id: String, title: String = "測試歌曲", artist: String = "範例歌手", duration: Double? = 214) -> LyricsCandidate {
            .init(id: .init(providerID: .lrcapi, recordID: id), title: title, artist: artist, duration: duration,
                lyrics: .init(lines: [.init(time: 0, text: "Synthetic benchmark content")], source: "LrcApi", isTimeSynced: false, providerID: .lrcapi))
        }
        let records = [candidate("exact"), candidate("wrong", artist: "不同歌手"),
            candidate("live", title: "測試歌曲 (Live)"), candidate("untimed", duration: nil)]
        func signatures(_ metadata: LyricsCanonicalMetadata) -> [String] {
            records.map { record in
                let value = LyricsCandidateScorer.decision(record, metadata: metadata)
                return [value.kind.rawValue, String(value.score), value.reason?.rawValue ?? "", value.hypothesisID ?? "",
                    value.scoreBreakdown.keys.sorted().map { $0 + ":" + String(value.scoreBreakdown[$0]!) }.joined(separator: ";")].joined(separator: "|")
            }
        }
        let expected = signatures(uncached)
        XCTAssertEqual(signatures(cached), expected)
        XCTAssertEqual(LyricsCandidateScorer.decision(records[1], metadata: cached).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(records[2], metadata: cached).kind, .rejected)
        XCTAssertTrue(records.allSatisfy { $0.lyrics.lines.first?.text == "Synthetic benchmark content" })
        let iterations = 4
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { XCTAssertEqual(signatures(uncached), expected) }
        let beforeMs = (ProcessInfo.processInfo.systemUptime - before) * 1000
        let after = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { XCTAssertEqual(signatures(cached), expected) }
        let afterMs = (ProcessInfo.processInfo.systemUptime - after) * 1000
        let evidence: [String: Any] = ["stage": "same fixture candidate scoring", "candidateCount": records.count,
            "iterations": iterations, "beforeMilliseconds": beforeMs, "afterMilliseconds": afterMs,
            "decisionEvidenceEqual": true, "sourceSettingsAndResultsCached": false,
            "fullLookupSpeedupValidated": false, "physicalDevice": false]
        let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-same-fixture-scoring-benchmark"; attachment.lifetime = .keepAlways; add(attachment)
        print("LYRICS_SCORING_LATENCY " + String(decoding: encoded, as: UTF8.self))
    }

    func testStageTimingEventsRetainLookupCorrelationWithoutLyricsOrURLs() throws {
        let context = LyricsLookupContext(songID: "synthetic", title: "Song", artist: "Singer", diagnosticLookupID: "stage-fixture")
        let event = LyricsLookupDiagnostics.Event(context: context, phase: .stageTiming,
            stage: "metadataAndHypotheses", stageElapsedMilliseconds: 12.5)
        XCTAssertEqual(event.lookupID, "stage-fixture")
        XCTAssertEqual(event.stageElapsedMilliseconds, 12.5)
        XCTAssertNil(event.title)
        XCTAssertNil(event.recordID)
        let invalid = LyricsLookupDiagnostics.Event(context: context, phase: .stageTiming,
            stage: "https://invalid.example", stageElapsedMilliseconds: .infinity)
        XCTAssertNil(invalid.stage)
        XCTAssertNil(invalid.stageElapsedMilliseconds)
    }

    func testObservedWhitespacePublisherCreditIsRetainedWithoutGuessingBareTitles() throws {
        let original = "蕭敬騰 會痛的石頭-華納official HQ官方版MV"
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "", duration: 288, hasYouTubeOrigin: true)))
        XCTAssertEqual(metadata.pair.title, "會痛的石頭")
        XCTAssertEqual(metadata.pair.artist, "蕭敬騰")
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).contains { $0.pair.title == "會痛的石頭" && $0.pair.artist == "蕭敬騰" })
        let bare = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "蕭敬騰 會痛的石頭", artist: "", hasYouTubeOrigin: true)))
        XCTAssertTrue(bare.pair.artist.isEmpty)
        XCTAssertEqual(bare.pair.title, "蕭敬騰 會痛的石頭")
        let trusted = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "Different singer", hasYouTubeOrigin: true)))
        XCTAssertEqual(trusted.pair.artist, "Different singer")
    }

    func testPreparedHypothesesNeverReuseOtherMetadataOrVersion() throws {
        let studio = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let live = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song (Live)", artist: "Other singer", duration: 230)))
        XCTAssertEqual(studio.hypotheses.first?.pair.title, "Song")
        XCTAssertEqual(live.hypotheses.first?.pair.title, "Song (Live)")
        XCTAssertEqual(live.hypotheses.first?.pair.artist, "Other singer")
        // This cache contains only pure metadata interpretations. Source settings,
        // lookup results, selection memory and negative results are never cached.
        XCTAssertEqual(studio.context.duration, 200)
        XCTAssertEqual(live.context.duration, 230)
    }

    func testMixedLanguageLyricFooterKeepsBothUncertainRolesWithoutSnippetInArtist() throws {
        let original = "歌曲甲 - 歌手乙『一段示例短句』【動態歌詞/Vietsub/Pinyin Lyrics】"
        let context = LyricsLookupContext(title: original, artist: "", duration: 214, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertTrue(metadata.hypotheses.contains { $0.pair.title == "歌曲甲" && $0.pair.artist == "歌手乙" })
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        XCTAssertEqual(context.title, original)
        XCTAssertFalse(metadata.hypotheses.contains { $0.pair.artist.contains("示例短句") && $0.id != "literal" })
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).contains { $0.pair.title == "歌曲甲" && $0.pair.artist == "歌手乙" })
        XCTAssertLessThanOrEqual(LyricsQueryPlanner.queries(metadata).count, 6)
        XCTAssertLessThanOrEqual(LyricsQueryPlanner.secondaryPairs(metadata).count, 6)
    }

    func testMusicMarkerAndPipeFooterDoNotContaminateSongIdentity() throws {
        let original = "歌手乙 - 歌曲甲♫『一段示例短句』『动态歌词 | 高音质 | pinyin Lyrics』"
        XCTAssertEqual(ChineseLyricsMetadataCleaner.preparedTitle(original), "歌手乙 - 歌曲甲")
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "", duration: 215, hasYouTubeOrigin: true)))
        XCTAssertTrue(metadata.hypotheses.contains { $0.pair.title == "歌曲甲" && $0.pair.artist == "歌手乙" })
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
    }

    func testFormalQuoteUnknownFooterAndLiveVersionStayProtected() {
        XCTAssertEqual(ChineseLyricsMetadataCleaner.preparedTitle("歌手乙 - 『正式歌名』【動態歌詞/Vietsub/Pinyin Lyrics】"), "歌手乙 - 『正式歌名』")
        let unknown = "歌手乙 - 歌曲甲『正式副標題』【動態歌詞/UnknownEdition】"
        XCTAssertTrue(ChineseLyricsMetadataCleaner.preparedTitle(unknown).contains("正式副標題"))
        let live = "歌手乙 - 歌曲甲 (Live)『正式副標題』【動態歌詞/Vietsub/Pinyin Lyrics】"
        XCTAssertTrue(ChineseLyricsMetadataCleaner.preparedTitle(live).contains("Live"))
        XCTAssertTrue(ChineseLyricsMetadataCleaner.preparedTitle(live).contains("正式副標題"))
    }

    func testCachedHypothesesPreserveAllIdentityEvidenceAndMeasureStageCost() throws {
        let context = LyricsLookupContext(title: "歌曲甲 - 歌手乙『一段示例短句』【動態歌詞/Vietsub/Pinyin Lyrics】",
            artist: "", duration: 214, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        func signatures(_ values: [LyricsIdentityHypothesis]) -> [String] {
            values.map { [$0.id, $0.pair.title, $0.pair.artist, $0.titleVariants.joined(separator: "|"),
                $0.evidence.rawValue, String($0.allowsAutomaticSelection), $0.normalization.map { $0.before + "|" + $0.after + "|" + $0.reason.rawValue }.joined(separator: ";")].joined(separator: "~") }
        }
        let expected = signatures(LyricsIdentityPolicy.hypotheses(metadata))
        XCTAssertEqual(signatures(metadata.hypotheses), expected)
        let iterations = 60
        var count = 0
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { count += LyricsIdentityPolicy.hypotheses(metadata).count }
        let recomputedMs = (ProcessInfo.processInfo.systemUptime - before) * 1000
        let cachedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { count -= metadata.hypotheses.count }
        let cachedMs = (ProcessInfo.processInfo.systemUptime - cachedStart) * 1000
        XCTAssertEqual(count, 0)
        XCTAssertLessThan(cachedMs, recomputedMs, "Immutable metadata reads must avoid reconstructing the same hypotheses")
        let evidence: [String: Any] = ["sourceSHA": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "CI attachment identifies source",
            "stage": "identity hypotheses only", "iterations": iterations, "recomputedMilliseconds": recomputedMs,
            "cachedMilliseconds": cachedMs, "identityEvidenceEqual": true, "fullLookupSpeedupValidated": false,
            "physicalDevice": false, "actualVocalAlignment": "NOT_RUN"]
        let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-identity-hypotheses-latency"; attachment.lifetime = .keepAlways; add(attachment)
        print("LYRICS_HYPOTHESES_LATENCY " + String(decoding: encoded, as: UTF8.self))
    }
}
