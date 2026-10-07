import XCTest
import ZIPFoundation
@testable import LovelyMusic

final class CommonLyricsLogicTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "CommonLyricsLogic-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }
    private func candidate(_ title: String = "Song", artist: String = "Singer", album: String? = nil) -> LyricsCandidate {
        .init(id: .init(providerID: .lrcapi, recordID: "synthetic"), title: title, artist: artist, duration: 200,
            lyrics: .init(lines: [.init(time: 1, text: "Synthetic regression line")], source: "LrcApi", providerID: .lrcapi), album: album)
    }

    func testLiteralTitlesAndUncertainRolesNeverBecomeAutomaticFacts() throws {
        for title in ["Title - Singer", "Singer - Title (Official Video)", "Love [Chapter Two]"] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: title, artist: "", hasYouTubeOrigin: true)))
            XCTAssertLessThanOrEqual(metadata.hypotheses.count, 4)
            XCTAssertTrue(metadata.hypotheses.contains { $0.evidence == .literal && $0.pair.title == title })
            let record = title == "Love [Chapter Two]" ? candidate(title, artist: "Actual Singer") : candidate("Title", artist: "Singer")
            let decision = LyricsCandidateScorer.decision(record, metadata: metadata)
            XCTAssertEqual(decision.kind, .relatedManual)
            XCTAssertLessThan(decision.score, 85)
            let result = try XCTUnwrap(LyricsCandidateScorer.choose([record], metadata: metadata, defaults: defaults()))
            XCTAssertTrue(result.lines.isEmpty, title)
            XCTAssertFalse(result.isTimeSynced)
            XCTAssertEqual(result.candidates.first?.identityDecision?.kind, .relatedManual)
        }
    }

    func testTrustedPerformerCannotBeOverwrittenAndUploaderRemainsUnknown() throws {
        let context = LyricsLookupContext(title: "Other Singer - Song", artist: "Trusted Singer",
            hasYouTubeOrigin: true, artistNameSource: .artistMetadata)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(metadata.pair.artist, "Trusted Singer")
        XCTAssertEqual(context.artist, "Trusted Singer")
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "Other Singer"), metadata: metadata).kind, .rejected)
        XCTAssertFalse(LyricsCandidateScorer.decision(candidate(artist: "Trusted Singer"), metadata: metadata).allowsAutomaticSelection)
        let uploader = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Upload Channel",
            hasYouTubeOrigin: true, artistNameSource: .uploader)))
        XCTAssertTrue(LyricsQueryPlanner.queries(uploader).allSatisfy { $0.endpoint == "search" && $0.pair.artist.isEmpty })
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "Someone"), metadata: uploader).kind, .relatedManual)
    }

    func testLegacyVideoCreditReplacementIsExplicitAndNeverChangesTrustedContext() throws {
        let title = "Rick Astley - Never Gonna Give You Up Official MV (官方頻道)"
        let legacy = try XCTUnwrap(LyricsLookupMetadata.cleaned(title: title, artist: "Uploader",
            allowVideoCredits: true, allowArtistReplacement: true))
        XCTAssertEqual(legacy.artist, "Rick Astley")
        XCTAssertEqual(legacy.title, "Never Gonna Give You Up")
        let trusted = try XCTUnwrap(LyricsLookupMetadata.cleaned(title: title, artist: "Trusted Singer",
            allowVideoCredits: true))
        XCTAssertEqual(trusted.artist, "Trusted Singer")
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: title, artist: "Trusted Singer",
            hasYouTubeOrigin: true, artistNameSource: .artistMetadata)))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Never Gonna Give You Up", artist: "Rick Astley"),
            metadata: metadata).kind, .rejected)
    }

    func testFullCoequalCreditSetsMatchWhileMainFeatOrderAndExtraGuestsDoNot() throws {
        let coequal = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "A & B")))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "B & A"), metadata: coequal).kind, .confirmed)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "A & C"), metadata: coequal).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "A & B & C"), metadata: coequal).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "A"), metadata: coequal).kind, .relatedManual)
        let featured = candidate("Song (feat. A)", artist: "B")
        XCTAssertEqual(LyricsCandidateScorer.decision(featured, metadata: coequal).kind, .relatedManual)
        let ordered = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "A feat. B")))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(artist: "B & A"), metadata: ordered).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(featured, metadata: ordered).kind, .rejected)
    }

    func testAlbumVersionEvidenceCannotSilentlyBecomeStudioOrAutomatic() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "Singer")))
        let record = candidate(album: "Album (Live)")
        XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: metadata).kind, .relatedManual)
        XCTAssertEqual(LyricsCandidateScorer.decision(record, metadata: metadata).reason, .versionMismatch)
        XCTAssertEqual(record.versionLabel, "live")
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([record], metadata: metadata, defaults: defaults()))
        XCTAssertTrue(result.lines.isEmpty)
        let live = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song (Live)", artist: "Singer")))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(), metadata: live).kind, .rejected)
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate("Song (Live)", album: "Album (Remix)"), metadata: live).kind, .rejected)
    }

    func testUnknownFieldsOrSubstringOverlapCannotRaiseIdentityConfidence() throws {
        for (expected, actual) in [("愛你", "不愛你"), ("倒流", "時光倒流"), ("Song", "Song (Remix)")] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: expected, artist: "Singer")))
            XCTAssertEqual(LyricsCandidateScorer.decision(candidate(actual), metadata: metadata).kind, .rejected)
        }
        let unknown = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Song", artist: "", hasYouTubeOrigin: true)))
        XCTAssertEqual(LyricsCandidateScorer.decision(candidate(), metadata: unknown).kind, .relatedManual)
        let original = "Singer【倒流 Revert】三立華劇《Work》插曲 Official Lyric Video"
        let span = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: original, artist: "", hasYouTubeOrigin: true)))
        XCTAssertTrue(span.hypotheses.contains { $0.pair.title == original })
        XCTAssertTrue(span.hypotheses.first?.normalization.contains { $0.before != $0.after } ?? false)
        XCTAssertTrue(LyricsQueryPlanner.queries(span).contains { $0.pair.title == "Revert" })
    }

    func testTimingEvidenceIsIndependentAndInvalidOrUnsupportedTimelinesStayPlain() throws {
        for difference in [0.933, 1.0, 1.001, 1.733, 7.207] {
            let lyrics = try XCTUnwrap(LyricsMatchingPolicy.lyrics(syncedLRC: "[00:01.00]Synthetic line", plainText: nil,
                recordingDuration: 200 + difference, videoDuration: 200, provider: .lrcapi))
            XCTAssertEqual(lyrics.isTimeSynced, difference <= 1)
            XCTAssertEqual(lyrics.timingState, difference <= 1 ? .structurallyCompatible : .durationMismatch)
        }
        for (body, state) in [("[00:01.00]Synthetic good\n[00:99.00]Synthetic invalid", LyricsTimingState.invalidTimestamp),
                              ("[offset:2000]\n[00:01.00]Synthetic line", .unsupportedTiming),
                              ("[00:01.00]Synthetic line [00:02.00]embedded", .invalidTimestamp)] {
            let lyrics = try XCTUnwrap(LyricsMatchingPolicy.lyrics(syncedLRC: body, plainText: nil,
                recordingDuration: 200, videoDuration: 200, provider: .lrcapi))
            XCTAssertFalse(lyrics.isTimeSynced); XCTAssertEqual(lyrics.timingState, state)
            XCTAssertTrue(lyrics.lines.allSatisfy { $0.time == 0 })
        }
        XCTAssertEqual(LyricsMatchingPolicy.parseLRCResult("[00:01.00][00:02.00]Synthetic line").lines.count, 2)
        let unknown = try XCTUnwrap(LyricsMatchingPolicy.lyrics(syncedLRC: "[00:01.00]Synthetic line", plainText: nil,
            recordingDuration: nil, videoDuration: 200, provider: .lrcapi))
        XCTAssertEqual(unknown.timingState, .timingUnknown)
    }

    /// Actual captures are routed by exact endpoint/title/artist, never by a cleaned test context.
    func testAllOriginalImportedAndPhoneContextsUseExactQueriesAndIndependentDecisions() async throws {
        let fixture = try object("captured_eight_lyrics")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8)
        var count = 0
        for field in ["title", "title_raw"] {
            for row in cases {
                let id = try XCTUnwrap(row["songID"] as? String), title = try XCTUnwrap(row["title"] as? String)
                let duration = try XCTUnwrap(row["duration"] as? Int)
                let pair = try XCTUnwrap(row["capturePair"] as? [String: String])
                let responses = try XCTUnwrap(row["responses"] as? [String: [[String: Any]]])
                let key = pair["track_name"]! + "|" + pair["artist_name"]!
                CommonLyricsTransport.configure(primary: responses["LRCLib"]!, secondary: responses["LrcApi"]!, keys: [key])
                let song = try imported(id: id, title: title, duration: duration, field: field)
                let result = try await lookup(song)
                XCTAssertEqual(song.title, title); XCTAssertEqual(song.artistName, "")
                XCTAssertTrue(CommonLyricsTransport.requests().contains("lrclib|" + key))
                XCTAssertTrue(CommonLyricsTransport.requests().contains("lrcapi|" + key))
                XCTAssertLessThanOrEqual(CommonLyricsTransport.requests().filter { $0.hasPrefix("lrclib|") }.count, 6)
                XCTAssertLessThanOrEqual(CommonLyricsTransport.requests().filter { $0.hasPrefix("lrcapi|") }.count, 6)
                if id == "3hw92j4SqrI" { XCTAssertNil(result) }
                else { XCTAssertFalse(result?.candidates.isEmpty ?? true) }
                if id == "dtVR0oi_N4U" {
                    XCTAssertTrue(result?.candidates.contains { $0.recordID == "1608356126" } ?? false)
                    XCTAssertTrue(result?.candidates.contains { $0.recordID == "1771958337" && $0.identityDecision?.kind == .relatedManual } ?? false)
                }
                if id == "4RVl7b0X88Y" {
                    XCTAssertEqual(result?.candidates.first { $0.recordID == "bf45912edca824532b9a9946b6ad4b9d" }?.identityDecision?.kind, .relatedManual)
                }
                for record in result?.candidates ?? [] {
                    XCTAssertNotEqual(record.identityDecision?.kind, .rejected)
                    XCTAssertFalse(record.lyrics.lines.isEmpty)
                    if record.duration == nil || abs(record.duration! - Double(duration)) > 1 { XCTAssertFalse(record.lyrics.isTimeSynced) }
                }
                count += 1
            }
        }
        let phone = try object("phone_build21_lyrics_metadata")
        let corrected: [String: (String, String)] = ["JSMKvZdOmPc": ("Goodbye", "潘嘉麗"),
            "g2R4HuBN7W8": ("健忘", "許茹芸"), "W0b6HramCug": ("繁華夢", "黃齡")]
        for row in try XCTUnwrap(phone["cases"] as? [[String: Any]]) {
            let id = row["songID"] as! String, original = row["original"] as! [String: Any], expected = corrected[id]!
            let key = expected.0 + "|" + expected.1
            var keys = Set([key])
            for q in row["queries"] as! [[String: Any]] where q["provider"] as? String == "lrcapi" {
                keys.insert((q["title"] as! String) + "|" + (q["artist"] as! String))
            }
            let records = (row["correct_artist_candidates_rejected"] as! [[String: Any]]).map { record -> [String: Any] in
                var result: [String: Any] = ["id": record["recordID"]!, "title": record["title"]!, "artist": record["artist"]!, "lyrics": "Synthetic diagnostic replay line"]
                if let duration = record["duration"] as? Double { result["duration"] = duration }
                return result
            }
            CommonLyricsTransport.configure(primary: [], secondary: records, keys: keys)
            let song = try imported(id: id, title: original["title"] as! String, duration: original["duration"] as! Int, field: "title_raw")
            let result = try await lookup(song)
            XCTAssertTrue(CommonLyricsTransport.requests().contains("lrcapi|" + key))
            XCTAssertEqual(Set(result?.candidates.map(\.recordID) ?? []), Set(records.map { $0["id"] as! String }))
            XCTAssertEqual(song.title, original["title"] as? String)
            XCTAssertFalse(result?.isTimeSynced ?? false)
            count += 1
        }
        let revert = try object("phone_build22_revert_metadata"), original = revert["original"] as! [String: Any]
        let accepted = revert["acceptedQuery"] as! [String: String], key = accepted["title"]! + "|" + accepted["artist"]!
        let records = (revert["candidates"] as! [[String: Any]]).map { record -> [String: Any] in
            ["id": record["recordID"]!, "title": record["title"]!, "artist": record["artist"]!,
             "duration": record["duration"]!, "lrc": "[00:01.00]Synthetic diagnostic replay line"]
        }
        CommonLyricsTransport.configure(primary: [], secondary: records, keys: [key], primary503: true)
        let song = try imported(id: original["songID"] as! String, title: original["title"] as! String,
            duration: original["duration"] as! Int, field: "title_raw")
        let result = try await lookup(song)
        XCTAssertTrue(CommonLyricsTransport.requests().contains("lrcapi|" + key))
        XCTAssertEqual(CommonLyricsTransport.requests().filter { $0.hasPrefix("lrclib|") }.count, 2)
        XCTAssertEqual(result?.candidates.map(\.recordID), [revert["correctRecordID"] as! String])
        XCTAssertEqual(result?.candidates.first?.identityDecision?.kind, .confirmed)
        XCTAssertEqual(song.title, original["title"] as? String)
        count += 1
        XCTAssertEqual(count, 20)
        print("COMMON_LOGIC_QUERY_REPLAY_CASES 20; synthetic content; new live requests 0")
    }

    private func object(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func imported(id: String, title: String, duration: Int, field: String) throws -> Song {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("MB3_All_Playlists.json"), zip = directory.appendingPathComponent("playlist.zip")
        try JSONSerialization.data(withJSONObject: ["songs": [["playlist_id": "1", "youtube_id": id, field: title,
            "duration_seconds": duration, "order": 1]]]).write(to: source)
        try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: false)
        return try XCTUnwrap(MB3PlaylistImporter.parse(zipURL: zip).playlists.first?.songs.first)
    }
    private func lookup(_ song: Song) async throws -> SyncedLyrics? {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommonLyricsTransport.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let store = try defaults()
        let repository = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: store),
            secondary: LrcApiService(session: session, defaults: store), defaults: store, secondaryEnabled: { true })
        return try await GetLyricsUseCase(repository: repository).execute(song: song)
    }
}

private final class CommonLyricsTransport: URLProtocol {
    private static let lock = NSLock()
    private static var primary = Data(), secondary = Data(), keys = Set<String>(), log: [String] = [], failPrimary = false
    static func configure(primary: [[String: Any]], secondary: [[String: Any]], keys: Set<String>, primary503: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.primary = try! JSONSerialization.data(withJSONObject: primary)
        self.secondary = try! JSONSerialization.data(withJSONObject: secondary)
        self.keys = keys; log = []; failPrimary = primary503
    }
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let first = url.host == "lrclib.net", primaryRoute = first && url.path == "/api/search"
        let secondaryRoute = url.host == "api.lrc.cx" && url.path == "/jsonapi"
        let title = items.first { $0.name == (first ? "track_name" : "title") }?.value ?? ""
        let artist = items.first { $0.name == (first ? "artist_name" : "artist") }?.value ?? ""
        let key = title + "|" + artist
        Self.lock.lock()
        Self.log.append((first ? "lrclib" : secondaryRoute ? "lrcapi" : "unknown") + "|" + key)
        let captured = (primaryRoute || secondaryRoute) && Self.keys.contains(key)
        let data = captured ? (first ? Self.primary : Self.secondary) : Data("[]".utf8)
        let status = first && Self.failPrimary ? 503 : primaryRoute || secondaryRoute ? 200 : 404
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
