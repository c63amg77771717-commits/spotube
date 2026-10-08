import Foundation
import XCTest
@testable import LovelyMusic

/// Explicit opt-in only. Normal regression runs never contact public providers.
final class AuthorizedRandomLyricsSampleTests: XCTestCase {
    func testCompositionKeysIncludeUncertainTitleRoles() throws {
        func keys(_ title: String, artist: String = "") throws -> Set<String> {
            LyricsCompositionIdentity.possibleTitleKeys(try XCTUnwrap(LyricsCanonicalMetadata(.init(title: title, artist: artist, hasYouTubeOrigin: true))))
        }
        let forward = try keys("Singer - Song")
        XCTAssertFalse(forward.isDisjoint(with: try keys("Song - Singer")))
        XCTAssertFalse(forward.isDisjoint(with: try keys("Other Singer - Song (Cover)")))
        XCTAssertFalse(forward.isDisjoint(with: try keys("Song (Live)", artist: "Singer")))
        let bilingual = try keys("Singer【倒流 Revert】Official MV")
        XCTAssertFalse(bilingual.isDisjoint(with: try keys("Revert", artist: "Singer")))
        XCTAssertFalse(bilingual.isDisjoint(with: try keys("倒流", artist: "Singer")))
        XCTAssertFalse(try keys("愛你", artist: "Singer").isDisjoint(with: try keys("爱你", artist: "Singer")))
        XCTAssertFalse(try keys("柯有綸 Alan Kuo - 哭笑不得")
            .isDisjoint(with: try keys("柯有纶 Alan Kuo - 不用擔心")))
        XCTAssertEqual(LyricsLookupMetadata.identityKey("DAVICHI(다비치)"), "davichi다비치")
        XCTAssertEqual(LyricsLookupMetadata.identityKey("ＡＢＣ ♪"), "abc♪")
        XCTAssertTrue(try keys("Singer - First Song", artist: "Singer")
            .isDisjoint(with: try keys("Singer - Second Song", artist: "Singer")))
        XCTAssertTrue(try keys("愛你", artist: "Singer").isDisjoint(with: try keys("不愛你", artist: "Singer")))
    }

    func testSharedPossiblePerformerDoesNotMakeDifferentSongsTheSameComposition() throws {
        func keys(_ title: String, artist: String = "") throws -> Set<String> {
            try compositionKeys(.init(title: title, artist: artist, hasYouTubeOrigin: true))
        }
        let first = try keys("戴佩妮  Penny Tai - 怎樣 What If We Still Stay Together? (官方完整版MV)")
        let second = try keys("戴佩妮 penny《單身潛逃》Official MV")
        XCTAssertTrue(first.isDisjoint(with: second), "A shared uncertain performer is not a shared composition")
        let left = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "柯有綸 Alan Kuo - 哭笑不得", artist: "", hasYouTubeOrigin: true)))
        let right = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "柯有纶 Alan Kuo - 不用擔心", artist: "", hasYouTubeOrigin: true)))
        XCTAssertFalse(LyricsCompositionIdentity.possibleTitleKeys(left).isDisjoint(with: LyricsCompositionIdentity.possibleTitleKeys(right)))
        XCTAssertTrue(LyricsCompositionIdentity.keys(left).isDisjoint(with: LyricsCompositionIdentity.keys(right)))
        XCTAssertTrue(left.requiresManualIdentityConfirmation)
        XCTAssertTrue(right.requiresManualIdentityConfirmation)
        // Preserve this sample's full title qualifier rather than inventing a shortened alias.
        XCTAssertFalse(first.isDisjoint(with: try keys("怎樣 What If We Still Stay Together? (官方完整版MV)", artist: "戴佩妮 Penny Tai")))
        XCTAssertFalse(try keys("Singer - Song").isDisjoint(with: try keys("Song - Singer")))
        XCTAssertFalse(try keys("Singer - Song").isDisjoint(with: try keys("Other Singer - Song (Cover)")))
    }

    func testAuthorizedFixedTwentySongSampleThroughProductionAdapters() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "authorized_random_lyrics_sample", withExtension: "json") else {
            throw XCTSkip("No explicitly authorized fixed twenty-row sample resource was prepared")
        }
        AuthorizedSampleHTTPTransport.configureMock(nil)
        let runContext = try LyricsLiveReceiptBuilder.context()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let selected = try XCTUnwrap(document["samples"] as? [[String: Any]])
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(document["seed"] as? Int, 20261006)
        let batch = try XCTUnwrap(document["batch"] as? Int)
        XCTAssertTrue([1, 2].contains(batch))
        // Validate all identities before the first service query, without replacing failed samples.
        var seenCompositions = Set(document["priorCompositionKeys"] as? [String] ?? [])
        var seenPossibleTitles = Set(document["priorPossibleTitleKeys"] as? [String] ?? [])
        var possibleTitleOverlaps: [[String: Any]] = []
        for row in selected {
            let context = LyricsLookupContext(title: row["title"] as! String, artist: row["artist"] as! String, hasYouTubeOrigin: true)
            let keys = Set(try compositionKeys(context).map(LyricsReceiptDigest.text))
            XCTAssertTrue(seenCompositions.isDisjoint(with: keys), "Composition projections overlap before any query; do not replace the original sample")
            guard seenCompositions.isDisjoint(with: keys) else { throw SampleValidationError.duplicateComposition }
            seenCompositions.formUnion(keys)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let possible = Set(LyricsCompositionIdentity.possibleTitleKeys(metadata).map(LyricsReceiptDigest.text))
            let overlap = possible.intersection(seenPossibleTitles)
            if !overlap.isEmpty {
                possibleTitleOverlaps.append(["sampleKey": row["sampleKey"] ?? "missing", "possibleTitleKeys": overlap.sorted(),
                    "classification": "ambiguous shared possible title; human composition ground truth NOT_RUN"])
            }
            seenPossibleTitles.formUnion(possible)
        }
        let suite = "AuthorizedLyricsSample-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let repository = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults, captureReceipts: true),
            secondary: LrcApiService(session: session, defaults: defaults, captureReceipts: true), defaults: defaults, secondaryEnabled: { true }, probeBothSources: true)
        var results: [[String: Any]] = []
        for (index, row) in selected.enumerated() {
            // Only these selected raw metadata fields cross into the test runner.
            let title = try XCTUnwrap(row["title"] as? String), artist = try XCTUnwrap(row["artist"] as? String)
            let duration = row["duration"] as? Int
            XCTAssertFalse(title.isEmpty)
            XCTAssertTrue(Set(row.keys).isSubset(of: ["title", "artist", "duration", "stratum", "sampleKey"]))
            // Reimport through the real importer using a surrogate identity; original video IDs and playlist names are absent.
            var imported: [String: Any] = ["youtube_id": String(format: "SAMP%07d", index), "title_raw": title,
                                          "artist": artist, "playlist_id": "sample", "order": index + 1]
            if let duration { imported["duration_seconds"] = duration }
            let data = try JSONSerialization.data(withJSONObject: ["songs": [imported]])
            let song = try XCTUnwrap(MB3PlaylistImporter.parseJSON(data).playlists.first?.songs.first)
            XCTAssertEqual(song.title, title.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(song.artistName, artist.trimmingCharacters(in: .whitespacesAndNewlines))
            AuthorizedSampleHTTPTransport.beginSample(index)
            let started = ProcessInfo.processInfo.systemUptime
            let report = try await GetLyricsUseCase(repository: repository).executeReport(song: song, includeDurationInQuery: false)
            let lookupMilliseconds = Int(max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000))
            let requests = AuthorizedSampleHTTPTransport.requests
            XCTAssertTrue(requests.allSatisfy { ($0["onlyTitleAndArtist"] as? Bool) == true })
            XCTAssertLessThanOrEqual(requests.count, 24)
            XCTAssertEqual(Set(requests.compactMap { $0["provider"] as? String }), ["lrclib", "lrcapi"])
            XCTAssertTrue(report.providers.allSatisfy { $0.successfulResponses <= 6 })
            if report.state == .synchronized || report.state == .confirmedPlain {
                let selectedIdentity = report.lyrics?.candidates.first { $0.id == report.lyrics?.selectedRecordID }
                XCTAssertEqual(selectedIdentity?.identityDecision?.kind, .confirmed, "Uncertain sample identities must never count as automatic success")
            }
            var receipt = try LyricsLiveReceiptBuilder.row(report, sample: row, batch: batch,
                wallMilliseconds: Double(lookupMilliseconds), phases: requests)
            let context = LyricsLookupContext(song: song)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            receipt["index"] = index
            receipt["compositionKeys"] = Array(try compositionKeys(context)).map(LyricsReceiptDigest.text).sorted()
            receipt["possibleTitleKeys"] = Array(LyricsCompositionIdentity.possibleTitleKeys(metadata)).map(LyricsReceiptDigest.text).sorted()
            receipt["requests"] = requests
            receipt["providers"] = report.providers.map { outcome in
                ["provider": outcome.providerID?.rawValue ?? "unknown", "result": outcome.kind.rawValue,
                 "receivedCount": outcome.receivedCount, "contentCandidateCount": outcome.contentCandidateCount,
                 "acceptedCount": outcome.acceptedCount, "successfulResponses": outcome.successfulResponses,
                 "failureCount": outcome.failures.count, "stageElapsedMilliseconds": outcome.stageTimings] as [String: Any]
            }
            receipt["automaticIdentity"] = report.state == .synchronized || report.state == .confirmedPlain
            receipt["selectionMode"] = report.lyrics?.selectionMethod ?? "noUsableResult"
            receipt["identityHumanGroundTruth"] = "NOT_RUN"
            receipt["actualVocalAlignment"] = "NOT_RUN"
            receipt["manualChoiceVerified"] = "NOT_RUN"
            results.append(receipt)
        }
        let result: [String: Any] = ["schema": "evantube-fixed20-live-v1", "evidenceKind": "nativeActualProviderResponses",
            "sourceQueriesAuthorized": true, "nativeCheckoutSHA": runContext["nativeCheckoutSHA"] ?? "missing",
            "nativeRunID": runContext["nativeRunID"] ?? "missing", "independentLookups": true,
            "seed": 20261006, "batch": batch, "previousManifestSHA256": document["previousManifestSHA256"] ?? NSNull(),
            "sampleCount": results.count, "nativeExecution": true, "realProviderQueries": true, "probeBothSources": true,
            "compositionKeyDefinition": "SHA256 of role anchored metadata projections; possible-title overlaps retained as digests",
            "compositionHumanGroundTruth": "NOT_RUN", "possibleTitleProjectionOverlaps": possibleTitleOverlaps,
            "realProviderResponses": results.contains { result in
                (result["requests"] as? [[String: Any]] ?? []).contains { ($0["httpStatus"] as? Int ?? 0) > 0 }
            }, "physicalDevice": false, "audioAlignmentValidated": false, "newSampleAfterFailures": false,
            "manifestSHA256": document["manifestSHA256"] ?? "not-provided", "results": results, "rows": results]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-authorized-twenty-song-sample-batch-" + String(batch); attachment.lifetime = .keepAlways; add(attachment)
        if let output = ProcessInfo.processInfo.environment["EVANTUBE_SAMPLE_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("AUTHORIZED_RANDOM_LYRICS_SAMPLE_COMPLETE 20; native real provider execution; not physical-device or alignment acceptance")
    }
    private enum SampleValidationError: Error { case duplicateComposition }
    private func compositionKeys(_ context: LyricsLookupContext) throws -> Set<String> {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        return LyricsCompositionIdentity.keys(metadata)
    }
}
