import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsDeviceLabelAndLatencyTests: XCTestCase {
    func testProviderStageEvidenceSurvivesCompositeRejectionAndRingEviction() async throws {
        let lyrics = SyncedLyrics(lines: [.init(time: 0, text: "Synthetic wrong performer content")], source: "LRCLib", isTimeSynced: false, providerID: .lrclib)
        let candidate = LyricsCandidate(id: .init(providerID: .lrclib, recordID: "wrong"), title: "Song", artist: "Wrong singer", duration: 200, lyrics: lyrics)
        let offered = SyncedLyrics(lines: [], source: "", isTimeSynced: false, candidates: [candidate])
        let primary = LyricsLookupReport.provider(.lrclib, lyrics: offered, received: 1,
            successfulResponses: 1, failures: [], stageTimings: ["candidateContentAndEvidence": 12.5])
        let secondary = LyricsLookupReport.provider(.lrcapi, lyrics: nil, received: 0, successfulResponses: 1, failures: [])
        let suite = "timing-retention-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = CompositeLyricsRepository(primary: TimingReportFixture(report: primary),
            secondary: TimingReportFixture(report: secondary), defaults: defaults, secondaryEnabled: { true })
        let context = LyricsLookupContext(title: "Song", artist: "Singer", duration: 200)
        let result = try await repository.lookup(context: context)
        XCTAssertEqual(result.state, .candidatesRejected)
        XCTAssertNil(result.lyrics)
        XCTAssertEqual(result.providers.first?.kind, .rejected)
        XCTAssertEqual(result.providers.first?.stageTimings["candidateContentAndEvidence"], 12.5)
        let ring = LyricsLookupDiagnostics(capacity: 8)
        for _ in 0..<20 { ring.record(.init(context: context, phase: .response)) }
        XCTAssertEqual(ring.events.count, 8)
        XCTAssertEqual(result.providers.first?.stageTimings["candidateContentAndEvidence"], 12.5)
    }

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
    func testPhoneticFooterProducesBothCleanRolesAndRetainsLiteral() throws {
        let original = "歌曲甲 - 歌手乙 拼音歌詞【一段示範短句，仍保留原始文字】Publisher Pin Yin Lyrics video music Chinese song"
        let context = LyricsLookupContext(title: original, artist: "", hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertTrue(metadata.hypotheses.contains { $0.pair.title == "歌曲甲" && $0.pair.artist == "歌手乙" })
        XCTAssertTrue(metadata.hypotheses.contains { $0.id == "literal" && $0.pair.title == original })
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        XCTAssertTrue(LyricsQueryPlanner.secondaryPairs(metadata).contains { $0.title == "歌曲甲" && $0.artist == "歌手乙" })
        XCTAssertEqual(context.title, original)
        let unknown = "歌曲甲 - 歌手乙 拼音歌詞【正式副標題】Unknown Edition Live"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(unknown), unknown)
    }

    func testSentenceSnippetAndNarrationAreDerivedWithoutDiscardingFormalMetadata() throws {
        let original = "歌手乙 - 歌曲甲「這是一段很長的示範歌詞，句子仍保留在原始資料裡。」"
        let context = LyricsLookupContext(title: original, artist: "歌手乙", hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(metadata.pair.title, "歌曲甲")
        XCTAssertEqual(context.title, original)
        XCTAssertTrue(metadata.hypotheses.contains { $0.id == "literal" && $0.pair.title == original })
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation, "An inferred lyric snippet cannot prove the original title")
        let narrative = "歌手乙《歌曲甲》，歌聲經典動聽，百聽不厭！"
        XCTAssertEqual(ChineseLyricsMetadataCleaner.preparedTitle(narrative), "歌手乙《歌曲甲》")
        let formal = "歌手乙 - 『正式歌名』"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(formal), formal)
        let subtitle = "歌手乙 - 歌曲甲『正式副標題』"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(subtitle), subtitle)
        let live = "歌手乙《歌曲甲》，Live 歌聲經典動聽！"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(live), live)
        let feature = "歌手乙 - 歌曲甲 (feat. 歌手丙) (Live)「一段很長的示範歌詞，仍須保留版本與合唱者。」"
        let cleaned = LyricsLookupMetadata.boundedQueryPresentation(feature)
        XCTAssertTrue(cleaned.contains("feat. 歌手丙")); XCTAssertTrue(cleaned.contains("Live"))
    }

    func testBoxSeparatorAndPresentationBracketNeverBecomeSongTitle() throws {
        let original = "歌手乙 ─ 歌曲甲 (有歌詞字幕 Lyrics)"
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "", hasYouTubeOrigin: true)))
        XCTAssertEqual(metadata.pair.title, "歌曲甲"); XCTAssertEqual(metadata.pair.artist, "歌手乙")
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        let caption = "歌手乙 Alias l 歌曲甲【高音質 動態歌詞 Lyrics】"
        let observed = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: caption, artist: "", hasYouTubeOrigin: true)))
        XCTAssertEqual(observed.pair.title, "歌曲甲")
        XCTAssertEqual(observed.pair.artist, "歌手乙 Alias")
        XCTAssertTrue(observed.requiresManualIdentityConfirmation)
        XCTAssertNil(LyricsLookupMetadata.bracketedVideoCredit(caption), "A presentation span is not a song span")
        let unknown = "歌手乙 Alias l 歌曲甲【正式副標題】"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(unknown), unknown)
        let bare = "歌手乙 Alias l 歌曲甲"
        XCTAssertEqual(LyricsLookupMetadata.boundedQueryPresentation(bare), bare)
    }

    private func repairCandidate(_ id: String, provider: LyricsProviderID = .lrclib, title: String = "Song",
                                 artist: String = "Singer", duration: Double? = 200, album: String? = "Album",
                                 text: String = "Synthetic verse", time: Double = 20,
                                 timing: LyricsTimingState = .structurallyCompatible) -> LyricsCandidate {
        .init(id: .init(providerID: provider, recordID: id), title: title, artist: artist, duration: duration,
              lyrics: .init(lines: [.init(time: 0, text: "Synthetic opening"), .init(time: time, text: text)],
                            source: provider.displayName, isTimeSynced: timing == .structurallyCompatible,
                            providerID: provider, timingState: timing), album: album)
    }

    private func repairDecisionSignature(_ value: LyricsIdentityDecision) -> String {
        [value.kind.rawValue, String(value.score), value.reason?.rawValue ?? "", value.hypothesisID ?? "",
         value.scoreBreakdown.keys.sorted().map { $0 + ":" + String(value.scoreBreakdown[$0]!) }.joined(separator: ";")].joined(separator: "|")
    }

    private func repairResultSignature(_ result: SyncedLyrics?) -> [String] {
        guard let result else { return ["nil"] }
        let timeline: [String] = result.lines.map { line in
            String(line.time) + "|" + line.text
        }
        let header: [String] = [result.providerID?.rawValue ?? "", result.source,
                                result.timingState.rawValue, timeline.joined(separator: ";")]
        let candidates: [String] = result.candidates.map { candidate in
            let record = candidate.providerID.rawValue + ":" + candidate.recordID
            let identity = repairDecisionSignature(candidate.identityDecision!)
            return record + "|" + identity
        }
        return header + candidates
    }

    func testLookupLocalReuseInvalidatesAllCandidateEvidenceAndContextChanges() throws {
        let context = LyricsLookupContext(songID: "one", title: "Song", artist: "Singer", duration: 200, diagnosticLookupID: "one")
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        let session = LyricsLookupScoringSession()
        let original = repairCandidate("one")
        let expected = repairDecisionSignature(LyricsCandidateScorer.decision(original, metadata: metadata))
        XCTAssertEqual(repairDecisionSignature(session.decision(original, metadata: metadata)), expected)
        XCTAssertEqual(repairDecisionSignature(session.decision(original, metadata: metadata)), expected)
        XCTAssertEqual(session.evaluationCount, 1); XCTAssertEqual(session.reuseCount, 1)
        let changedSource = LyricsCandidate(id: original.id, title: original.title, artist: original.artist,
            duration: original.duration, lyrics: .init(lines: original.lyrics.lines, source: "Changed source attribution",
                providerID: .lrcapi), album: original.album)
        let emptyContent = LyricsCandidate(id: original.id, title: original.title, artist: original.artist,
            duration: original.duration, lyrics: .init(lines: [], source: "LRCLib", providerID: .lrclib), album: original.album)
        let mutations = [changedSource, emptyContent, repairCandidate("one", provider: .lrcapi), repairCandidate("one", title: "Song (Live)"),
                         repairCandidate("one", artist: "Other singer"), repairCandidate("one", duration: 201),
                         repairCandidate("one", album: "Album (Demo)"), repairCandidate("one", text: "Changed content"),
                         repairCandidate("one", time: 25), repairCandidate("one", timing: .plainOnly),
                         repairCandidate("one", album: nil)]
        for candidate in mutations {
            let before = session.evaluationCount
            XCTAssertEqual(repairDecisionSignature(session.decision(candidate, metadata: metadata)),
                           repairDecisionSignature(LyricsCandidateScorer.decision(candidate, metadata: metadata)))
            XCTAssertEqual(session.evaluationCount, before + 1)
        }
        let changed = try XCTUnwrap(LyricsCanonicalMetadata(.init(songID: "two", title: "Song", artist: "Other singer", duration: 200, diagnosticLookupID: "two")))
        let before = session.evaluationCount
        XCTAssertEqual(session.decision(original, metadata: changed).kind, .rejected)
        XCTAssertEqual(session.evaluationCount, before + 1)
        let secondInvocation = try XCTUnwrap(LyricsCanonicalMetadata(.init(songID: "one", title: "Song", artist: "Singer", duration: 200, diagnosticLookupID: "new-invocation")))
        _ = session.decision(original, metadata: secondInvocation)
        XCTAssertEqual(session.evaluationCount, before + 2)
        _ = session.decision(original, metadata: metadata, remembered: original.id)
        XCTAssertEqual(session.evaluationCount, before + 3)
        let otherContexts = [
            LyricsLookupContext(songID: "one", title: "Song", artist: "Singer", duration: 220, diagnosticLookupID: "one"),
            LyricsLookupContext(songID: "one", title: "Song (Live)", artist: "Singer", duration: 200, diagnosticLookupID: "one"),
            LyricsLookupContext(songID: "one", title: "Song", artist: "Other singer", duration: 200, diagnosticLookupID: "one"),
            LyricsLookupContext(songID: "one", title: "Song", artist: "Singer", album: "Album (Demo)", duration: 200, diagnosticLookupID: "one"),
            LyricsLookupContext(songID: "one", title: "Song", artist: "Singer", duration: 200, hasYouTubeOrigin: true,
                artistNameSource: .uploader, diagnosticLookupID: "one")
        ]
        for context in otherContexts {
            let other = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let evaluations = session.evaluationCount
            XCTAssertEqual(repairDecisionSignature(session.decision(original, metadata: other)),
                repairDecisionSignature(LyricsCandidateScorer.decision(original, metadata: other)))
            XCTAssertEqual(session.evaluationCount, evaluations + 1)
        }
        let fresh = LyricsLookupScoringSession()
        _ = fresh.decision(original, metadata: metadata)
        XCTAssertEqual(fresh.reuseCount, 0)
    }

    func testCanceledLookupCannotConsumeReusedScoringDecisions() async throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let candidate = repairCandidate("cancel")
        let task = Task { () -> (Int, Int) in
            let session = LyricsLookupScoringSession()
            _ = session.decision(candidate, metadata: metadata)
            withUnsafeCurrentTask { $0?.cancel() }
            _ = session.decision(candidate, metadata: metadata)
            return (session.evaluationCount, session.reuseCount)
        }
        let counts = await task.value
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }

    func testIdenticalStrongTimedEvidenceDoesNotCreateFalseSelectionMargin() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let suite = "identical-evidence-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let first = repairCandidate("one"), second = repairCandidate("two", provider: .lrcapi)
        let conservative = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: defaults, groupEquivalentEvidence: false))
        XCTAssertTrue(conservative.lines.isEmpty)
        let grouped = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: defaults))
        XCTAssertFalse(grouped.lines.isEmpty)
        XCTAssertEqual(grouped.candidates.count, 2, "Keep both IDs for attribution and remembered choice")
        XCTAssertEqual(LyricsRecordingEvidence.groups(grouped.candidates), [[second.id, first.id]])
        LyricsSelectionStore.select(second.id, for: metadata.context.selectionKey, defaults: defaults)
        let remembered = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: defaults))
        XCTAssertEqual(remembered.providerID, .lrcapi)
    }

    func testSameNameOrWeakRecordingEvidenceNeverGroupsDifferentCandidates() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let suite = "separate-evidence-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let first = repairCandidate("one")
        for second in [repairCandidate("two", text: "Different recording words"), repairCandidate("two", time: 21),
                       repairCandidate("two", duration: 201), repairCandidate("two", album: "Other album"),
                       repairCandidate("two", album: nil), repairCandidate("two", timing: .plainOnly)] {
            let result = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: defaults))
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(LyricsRecordingEvidence.groups(result.candidates).isEmpty)
        }
        let uncertain = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Singer - Song", artist: "", duration: 200, hasYouTubeOrigin: true)))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([first, repairCandidate("two", provider: .lrcapi)], metadata: uncertain, defaults: defaults))
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(LyricsRecordingEvidence.groups(result.candidates).isEmpty)
        for wrong in [repairCandidate("wrong", artist: "Other singer"), repairCandidate("live", title: "Song (Live)")] {
            XCTAssertEqual(LyricsCandidateScorer.decision(wrong, metadata: metadata).kind, .rejected)
        }
    }

    func testReuseHonorsRememberedSelectionChangesWithIdenticalOracleResults() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let suite = "reuse-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let records = [repairCandidate("one"), repairCandidate("two", text: "Other recording")]
        let session = LyricsLookupScoringSession()
        for selected in [nil, records[1].id, records[0].id] as [LyricsRecordID?] {
            if let selected { LyricsSelectionStore.select(selected, for: metadata.context.selectionKey, defaults: defaults) }
            let oracle = LyricsCandidateScorer.choose(records, metadata: metadata, defaults: defaults)
            let reused = LyricsCandidateScorer.choose(records, metadata: metadata, defaults: defaults, scoringSession: session)
            XCTAssertEqual(repairResultSignature(reused), repairResultSignature(oracle))
        }
        XCTAssertEqual(session.evaluationCount, 6)
    }

    func testSameFixtureEvidenceAndAccumulatedSelectionScoringReuseLatency() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "範例歌手 - 測試歌曲『一句示範短句』【動態歌詞/Vietsub/Pinyin Lyrics】",
            artist: "", duration: 214, hasYouTubeOrigin: true)))
        let records = [repairCandidate("exact", title: "測試歌曲", artist: "範例歌手", duration: 214),
                       repairCandidate("wrong", title: "測試歌曲", artist: "不同歌手", duration: 214),
                       repairCandidate("live", title: "測試歌曲 (Live)", artist: "範例歌手", duration: 214),
                       repairCandidate("untimed", title: "測試歌曲", artist: "範例歌手", duration: nil)]
        let suite = "reuse-benchmark-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let iterations = 6
        func execute(_ session: LyricsLookupScoringSession?) -> [String] {
            var output: [String] = []
            for count in 1...records.count {
                let prefix = Array(records.prefix(count))
                output += prefix.map { candidate in
                    let evidence = LyricsCandidateEvidence(provider: candidate.providerID, recordID: candidate.recordID,
                        title: candidate.title, artist: candidate.artist, album: candidate.album, duration: candidate.duration,
                        metadata: metadata, candidate: candidate, scoringSession: session)
                    return [evidence.identity, String(evidence.score), evidence.reason ?? "", evidence.hypothesisID ?? "",
                            evidence.scoreBreakdown.keys.sorted().map { $0 + ":" + String(evidence.scoreBreakdown[$0]!) }.joined(separator: ";")].joined(separator: "|")
                }
                output += repairResultSignature(LyricsCandidateScorer.choose(prefix, metadata: metadata, defaults: defaults, scoringSession: session))
            }
            return output
        }
        let expected = execute(nil)
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { XCTAssertEqual(execute(nil), expected) }
        let beforeMs = (ProcessInfo.processInfo.systemUptime - before) * 1000
        let session = LyricsLookupScoringSession()
        let after = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { XCTAssertEqual(execute(session), expected) }
        let afterMs = (ProcessInfo.processInfo.systemUptime - after) * 1000
        XCTAssertEqual(session.evaluationCount, records.count)
        XCTAssertGreaterThan(session.reuseCount, session.evaluationCount)
        XCTAssertLessThan(afterMs, beforeMs)
        let evidence: [String: Any] = ["stage": "same fixture evidence and accumulated candidate ranking",
            "candidateCount": records.count, "iterations": iterations,
            "beforeMilliseconds": beforeMs, "afterMilliseconds": afterMs,
            "policyEvaluationsAfter": session.evaluationCount, "pureDecisionReuses": session.reuseCount,
            "decisionAndCandidateEvidenceEqual": true, "resultOrProviderFailuresCached": false,
            "fullLookupSpeedupValidated": false, "physicalDevice": false, "actualVocalAlignment": "NOT_RUN"]
        let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-lookup-local-scoring-reuse"; attachment.lifetime = .keepAlways; add(attachment)
        print("LYRICS_LOOKUP_SCORING_REUSE_LATENCY " + String(decoding: encoded, as: UTF8.self))
    }

    func testCompleteConcatenatedDuetCaptionRetainsManualIdentity() throws {
        let original = "甲乙丙丁戊己神級對唱《示例歌名》，歌聲經典動聽，百聽不厭！"
        let context = LyricsLookupContext(title: original, artist: "", duration: 200, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        let suite = "duet-caption-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for artist in ["甲乙丙 & 丁戊己", "丁戊己 / 甲乙丙"] {
            let candidate = repairCandidate("duet", title: "示例歌名", artist: artist)
            let decision = LyricsCandidateScorer.decision(candidate, metadata: metadata)
            XCTAssertEqual(decision.kind, .relatedManual)
            XCTAssertEqual(decision.score, 84)
            XCTAssertFalse(decision.allowsAutomaticSelection)
            let result = try XCTUnwrap(LyricsCandidateScorer.choose([candidate], metadata: metadata, defaults: defaults))
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertEqual(result.candidates.first?.artist, artist)
        }
        XCTAssertEqual(context.title, original)
        XCTAssertEqual(metadata.originalTitle, original)
        XCTAssertEqual(metadata.pair.artist, "甲乙丙丁戊己")
    }

    func testConcatenatedDuetNeedsCaptionAndCannotOverrideSuppliedPerformer() throws {
        let record = repairCandidate("duet", title: "示例歌名", artist: "甲乙丙 & 丁戊己")
        let contexts = [
            LyricsLookupContext(title: "甲乙丙丁戊己《示例歌名》Official MV", artist: "", duration: 200, hasYouTubeOrigin: true),
            LyricsLookupContext(title: "甲乙丙丁戊己對唱《示例歌名》Official MV", artist: "另外歌手", duration: 200, hasYouTubeOrigin: true),
            LyricsLookupContext(title: "甲乙丙丁戊己對唱《示例歌名》", artist: "甲乙丙丁戊己", duration: 200)
        ]
        for context in contexts {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: metadata).kind, .rejected)
        }
        let label = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "甲乙丙丁戊己對唱【高音質 動態歌詞 Lyrics】", artist: "", duration: 200, hasYouTubeOrigin: true)))
        XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: label).kind, .rejected)
    }

    func testConcatenatedDuetRejectsPartialExtraGuestWrongSongAndVersions() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "甲乙丙丁戊己對唱《示例歌名》Official MV", artist: "", duration: 200, hasYouTubeOrigin: true)))
        let records = [
            repairCandidate("partial", title: "示例歌名", artist: "甲乙丙"),
            repairCandidate("extra", title: "示例歌名", artist: "甲乙丙 & 丁戊己 & 庚辛壬"),
            repairCandidate("wrong", title: "示例歌名", artist: "甲乙丙 & 庚辛壬"),
            repairCandidate("song", title: "另外歌名", artist: "甲乙丙 & 丁戊己"),
            repairCandidate("live", title: "示例歌名 (Live)", artist: "甲乙丙 & 丁戊己"),
            repairCandidate("cover", title: "示例歌名 (Cover)", artist: "甲乙丙 & 丁戊己")
        ]
        for record in records {
            XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: metadata).kind, .rejected, record.recordID)
        }
    }

    func testDottedFeatCreditKeepsPrimaryOrderAndCompleteGuests() throws {
        for credit in ["Singer feat.Guest", "Singer ft.Guest", "Singer featuring.Guest", "Singer feat. Guest"] {
            XCTAssertEqual(LyricsCanonicalMetadata.creditComponents(credit), ["Singer", "Guest"])
        }
        for opaque in ["Gift.Beverly", "Singer ftGuest", "feat.Guest"] {
            XCTAssertEqual(LyricsCanonicalMetadata.creditComponents(opaque), [opaque])
        }
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer feat.Guest", duration: 200)))
        let complete = repairCandidate("complete", artist: "Singer feat. Guest")
        XCTAssertEqual(LyricsCandidateScorer.decision(complete, metadata: metadata).kind, .confirmed)
        let reversed = repairCandidate("reversed", artist: "Guest feat.Singer")
        XCTAssertEqual(LyricsCandidateScorer.decision(reversed, metadata: metadata).reason, .primaryPerformerMismatch)
        let wrong = repairCandidate("wrong", artist: "Singer feat.Other")
        XCTAssertEqual(LyricsCandidateScorer.decision(wrong, metadata: metadata).kind, .rejected)
        let partial = repairCandidate("partial", artist: "Singer")
        let partialDecision = LyricsCandidateScorer.decision(partial, metadata: metadata)
        XCTAssertEqual(partialDecision.kind, .relatedManual)
        XCTAssertEqual(partialDecision.reason, .guestMismatch)
        XCTAssertFalse(partialDecision.allowsAutomaticSelection)
    }

    func testBracketedFeaturingJapaneseVideoLabelPreservesTVQualifier() throws {
        let original = "Ensemble feat. Voice / 『Theme』（TVオープニングサイズ）ミュージックビデオ"
        let context = LyricsLookupContext(title: original, artist: "", duration: 88, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(metadata.pair.artist, "Ensemble feat. Voice")
        XCTAssertEqual(LyricsLookupMetadata.identityKey(metadata.pair.title), LyricsLookupMetadata.identityKey("Theme (TVオープニングサイズ)"))
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).contains { $0.pair.title.contains("TVオープニングサイズ") && !$0.pair.title.contains("ミュージックビデオ") })
        XCTAssertLessThanOrEqual(LyricsQueryPlanner.queries(metadata).count, 6)
        let complete = repairCandidate("tv", title: "Theme (TVオープニングサイズ)", artist: "Ensemble feat.Voice", duration: 87.573)
        XCTAssertEqual(LyricsCandidateScorer.decision(complete, metadata: metadata).kind, .confirmed)
        for record in [repairCandidate("full", title: "Theme", artist: "Ensemble feat.Voice", duration: 88),
                       repairCandidate("wrong", title: "Theme (TVオープニングサイズ)", artist: "Other feat.Voice", duration: 88),
                       repairCandidate("order", title: "Theme (TVオープニングサイズ)", artist: "Voice feat.Ensemble", duration: 88),
                       repairCandidate("live", title: "Theme (TVオープニングサイズ) (Live)", artist: "Ensemble feat.Voice", duration: 88)] {
            XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: metadata).kind, .rejected, record.recordID)
        }
        XCTAssertEqual(context.title, original)
        let noTV = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Ensemble feat.Voice / 『Theme』ミュージックビデオ", artist: "", duration: 200, hasYouTubeOrigin: true)))
        XCTAssertEqual(noTV.pair.artist, "Ensemble feat.Voice")
        XCTAssertEqual(noTV.pair.title, "Theme")
        let missingGuest = repairCandidate("missing", title: "Theme (TVオープニングサイズ)", artist: "Ensemble", duration: 88)
        let missingDecision = LyricsCandidateScorer.decision(missingGuest, metadata: metadata)
        XCTAssertEqual(missingDecision.kind, .relatedManual)
        XCTAssertEqual(missingDecision.reason, .guestMismatch)
        XCTAssertFalse(missingDecision.allowsAutomaticSelection)
    }

    func testJapaneseVideoLabelDoesNotStripUnknownSuffixOrVersions() throws {
        let presented = "Band『Theme』(TVオープニングサイズ)ミュージックビデオ"
        let clean = LyricsLookupMetadata.strippingVideoPresentation(presented)
        XCTAssertTrue(clean.contains("TVオープニングサイズ"))
        XCTAssertFalse(clean.contains("ミュージックビデオ"))
        let unknown = presented + " 特別編集"
        XCTAssertEqual(LyricsLookupMetadata.strippingVideoPresentation(unknown), unknown)
        XCTAssertEqual(LyricsLookupMetadata.strippingVideoPresentation("ミュージックビデオ"), "ミュージックビデオ")
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Band『Theme (Live)』ミュージックビデオ", artist: "", duration: 200, hasYouTubeOrigin: true)))
        XCTAssertTrue(metadata.versionTags.contains("live"))
        XCTAssertEqual(LyricsCandidateScorer.decision(repairCandidate("studio", title: "Theme", artist: "Band"), metadata: metadata).kind, .rejected)
    }

    func testDottedFeatureSongViewsRetainLiteralAndRejectWrongGuest() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer feat.Guest", duration: 200)))
        let complete = repairCandidate("complete", title: "Song (feat.Guest)", artist: "Singer")
        XCTAssertEqual(LyricsCandidateScorer.decision(complete, metadata: metadata).kind, .confirmed)
        let wrong = repairCandidate("wrong", title: "Song (feat.Other)", artist: "Singer")
        XCTAssertEqual(LyricsCandidateScorer.decision(wrong, metadata: metadata).kind, .rejected)
        let unknown = repairCandidate("unknown", title: "Song (Different Edition)", artist: "Singer feat.Guest")
        XCTAssertEqual(LyricsCandidateScorer.decision(unknown, metadata: metadata).kind, .rejected)
        let original = "Singer - Song feat.Guest"
        let video = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "", duration: 200, hasYouTubeOrigin: true)))
        XCTAssertEqual(video.pair.artist, "Singer feat. Guest")
        XCTAssertEqual(video.pair.title, "Song")
        XCTAssertEqual(video.originalTitle, original)
        XCTAssertTrue(video.requiresManualIdentityConfirmation)
    }

    func testUnknownOrDifferentFullTimelineNeverGroupsSameMetadata() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer", duration: 200)))
        let suite = "strict-timeline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = repairCandidate("first")
        for second in [repairCandidate("second", provider: .lrcapi, time: 20.001),
                       repairCandidate("second", provider: .lrcapi, timing: .timingUnknown),
                       repairCandidate("second", provider: .lrcapi, text: "Different whole text")] {
            let result = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: defaults))
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertEqual(result.candidates.count, 2)
            XCTAssertTrue(LyricsRecordingEvidence.groups(result.candidates).isEmpty)
        }
        let exact = repairCandidate("exact", provider: .lrcapi)
        let grouped = try XCTUnwrap(LyricsCandidateScorer.choose([first, exact], metadata: metadata, defaults: defaults))
        XCTAssertFalse(grouped.lines.isEmpty)
        XCTAssertEqual(grouped.candidates.count, 2)
        XCTAssertEqual(LyricsRecordingEvidence.groups(grouped.candidates).count, 1)
        // These are synthetic controlled arrays, not proof about captured provider recordings.
    }

    func testSavedFortyIdentityMetadataReplayCannotProveLyricsEquivalence() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "saved_40_candidate_identity_metadata", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let samples = try XCTUnwrap(document["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 40)
        XCTAssertEqual(document["providerTextAndTimelineStored"] as? Bool, false)
        let suite = "saved-forty-offline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var modes: [String: Int] = [:]
        var rows: [[String: Any]] = []
        for (index, sample) in samples.enumerated() {
            let title = try XCTUnwrap(sample["title"] as? String)
            let artist = try XCTUnwrap(sample["artist"] as? String)
            var imported: [String: Any] = ["youtube_id": String(format: "RPLY%07d", index), "title_raw": title,
                                          "artist": artist, "playlist_id": "offline", "order": index + 1]
            if let duration = sample["duration"] as? Int { imported["duration_seconds"] = duration }
            let importedData = try JSONSerialization.data(withJSONObject: ["songs": [imported]])
            let song = try XCTUnwrap(MB3PlaylistImporter.parseJSON(importedData).playlists.first?.songs.first)
            XCTAssertEqual(song.title, title)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(LyricsLookupContext(song: song, includeDurationInQuery: false)))
            let records = try XCTUnwrap(sample["candidates"] as? [[String: Any]])
            var candidates: [LyricsCandidate] = []
            for record in records {
                guard let providerRaw = record["provider"] as? String, let provider = LyricsProviderID(rawValue: providerRaw),
                      let id = record["recordID"] as? String, let track = record["title"] as? String,
                      let performer = record["artist"] as? String else { continue }
                let present = (record["contentLineCount"] as? Int ?? 0) > 0
                // Only known nonemptiness is replayed. Text/timestamps are not provider data.
                let lines: [LyricLine] = present ? [.init(time: 0, text: "Synthetic content-presence marker; actual text/timeline NOT_CAPTURED")] : []
                let timingRaw = record["timing"] as? String ?? "plainOnly"
                let timing = LyricsTimingState(rawValue: timingRaw) ?? .plainOnly
                let lyrics = SyncedLyrics(lines: lines, source: provider.displayName, isTimeSynced: false,
                                          providerID: provider, timingState: timing)
                let duration = (record["duration"] as? NSNumber)?.doubleValue
                let candidate = LyricsCandidate(id: .init(providerID: provider, recordID: id), title: track,
                                                artist: performer, duration: duration, lyrics: lyrics, album: record["album"] as? String)
                candidates.append(candidate)
            }
            let chosen = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, scoringSession: LyricsLookupScoringSession())
            let mode = chosen == nil ? "rejected" : chosen!.lines.isEmpty ? "manual" : "automatic"
            let key = try XCTUnwrap(sample["sampleKey"] as? String)
            XCTAssertEqual(mode, sample["expectedIdentityOnlyMode"] as? String, key + " / " + title)
            XCTAssertTrue(LyricsRecordingEvidence.groups(chosen?.candidates ?? []).isEmpty,
                          "A metadata-only artifact cannot prove equal full text and timestamps")
            modes[mode, default: 0] += 1
            let identities: [[String: Any]] = (chosen?.candidates ?? []).map { candidate in
                ["record": candidate.providerID.rawValue + ":" + candidate.recordID,
                 "identity": candidate.identityDecision?.kind.rawValue ?? "unknown", "score": candidate.identityDecision?.score ?? 0]
            }
            rows.append(["batch": sample["batch"] as? Int ?? 0, "sampleKey": key, "before": sample["originalSelectionMode"] as? String ?? "unknown",
                         "after": mode, "acceptedIdentityMetadata": identities])
        }
        let evidence: [String: Any] = ["fixtureSourceSHA": document["sourceSHA"] as? String ?? "unknown",
            "compiledSourceSHA": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "attachment identifies source",
            "sampleCount": 40, "networkRequests": 0, "syntheticContentPresenceMarkersOnly": true,
            "selectionModes": modes, "rows": rows, "providerTextAndTimelineEquivalence": "NOT_RUN",
            "manualChoiceVerified": "NOT_RUN", "physicalDevice": false, "actualVocalAlignment": "NOT_RUN"]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-saved40-offline-identity-metadata-replay"
        attachment.lifetime = .keepAlways; add(attachment)
        print("LYRICS_SAVED_FORTY_IDENTITY_REPLAY " + String(decoding: data, as: UTF8.self))
    }

}

private struct TimingReportFixture: LyricsRepositoryProtocol {
    let report: LyricsLookupReport
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport { report }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { report.lyrics }
}
