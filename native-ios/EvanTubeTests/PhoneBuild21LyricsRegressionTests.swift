import XCTest
@testable import LovelyMusic

final class PhoneBuild21LyricsRegressionTests: XCTestCase {
    private struct Fixture: Decodable {
        let sourceDiagnosticSHA256: String
        let sourceBuild: Int
        let cases: [Case]
    }
    private struct Case: Decodable {
        let songID: String
        let original: Original
        let derived: Pair
        let queries: [Query]
        let correct_artist_candidates_rejected: [Record]
        let failure_reasons: [String: Int]
    }
    private struct Original: Decodable { let title, artist: String; let duration: Int }
    private struct Pair: Decodable { let title, artist: String }
    private struct Query: Decodable { let provider, endpoint, title, artist: String }
    private struct Record: Decodable { let recordID, title, artist, reason: String; let duration: Double? }

    func testPhoneMetadataProducesCorrectQueriesAndAcceptsPreviouslyRejectedRecordIDs() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "phone_build21_lyrics_metadata", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.sourceBuild, 21)
        XCTAssertEqual(fixture.sourceDiagnosticSHA256, "837c37de1780f06ebba4d5c89685705a243d6be05be7fa02a5fc25143bf05465")
        var report: [[String: Any]] = []
        for c in fixture.cases {
            let song = Song(id: c.songID, title: c.original.title, artistName: c.original.artist, artistId: nil,
                albumName: nil, albumId: nil, duration: c.original.duration, thumbnailURL: nil)
            let context = LyricsLookupContext(song: song)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let expected: (String, String)
            switch c.songID {
            case "JSMKvZdOmPc": expected = ("Goodbye", "潘嘉麗")
            case "g2R4HuBN7W8": expected = ("健忘", "許茹芸")
            case "W0b6HramCug": expected = ("繁華夢", "黃齡")
            default: XCTFail("Unexpected phone case"); continue
            }
            let queries = LyricsQueryPlanner.queries(metadata)
            let secondary = LyricsQueryPlanner.secondaryPairs(metadata)
            XCTAssertTrue(queries.contains { $0.pair.title == expected.0 && $0.pair.artist == expected.1 }, c.songID)
            XCTAssertTrue(secondary.contains { $0.title == expected.0 && $0.artist == expected.1 }, c.songID)
            XCTAssertNil(metadata.alternateVideoPair, "Explicit bracket roles must suppress whitespace hypotheses")
            XCTAssertFalse(metadata.requiresManualIdentityConfirmation, "Explicit song spans are not ambiguous whitespace credits")
            XCTAssertFalse((queries.map { $0.pair.title } + secondary.map { $0.title }).contains("Kelly Pan [Goodbye]"))
            XCTAssertLessThanOrEqual(queries.count, 6)
            XCTAssertLessThanOrEqual(secondary.count, 6)
            XCTAssertEqual(context.title, c.original.title)
            XCTAssertEqual(context.artist, c.original.artist)
            XCTAssertEqual(context.duration, c.original.duration)
            XCTAssertEqual(context.selectionKey, "song:" + c.songID)

            let records: [[String: Any]] = c.correct_artist_candidates_rejected.map {
                var record: [String: Any] = ["id": $0.recordID, "title": $0.title, "artist": $0.artist,
                    "lyrics": "Synthetic regression line, not captured lyrics"]
                if let duration = $0.duration { record["duration"] = duration }
                return record
            }
            // Only exact known query keys receive a response. New corrected keys
            // use synthetic content with phone-observed candidate metadata. This
            // verifies routing and scoring; it makes no live availability claim.
            let routes = c.queries.filter { $0.provider == "lrcapi" }.map { $0.title + "|" + $0.artist }
                + [expected.0 + "|" + expected.1]
            PhoneLyricsProtocol.configure(routes: Set(routes), records: try JSONSerialization.data(withJSONObject: records))
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PhoneLyricsProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let suite = "phone-build21-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            LyricsLookupDiagnostics.shared.clear()
            let repository = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults),
                secondary: LrcApiService(session: session, defaults: defaults), defaults: defaults, secondaryEnabled: { true })
            let result = try await GetLyricsUseCase(repository: repository).execute(song: song)
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.songID == c.songID }
            let requested = PhoneLyricsProtocol.queries()
            XCTAssertTrue(requested.contains("lrcapi|" + expected.0 + "|" + expected.1), c.songID)
            if c.songID == "W0b6HramCug" {
                XCTAssertEqual(c.correct_artist_candidates_rejected.count, 5)
                XCTAssertTrue(c.correct_artist_candidates_rejected.allSatisfy { $0.reason == "titleMismatch" })
                let actual = Set(result?.candidates.map(\.recordID) ?? [])
                XCTAssertEqual(actual, Set(c.correct_artist_candidates_rejected.map(\.recordID)))
                XCTAssertTrue(result?.candidates.allSatisfy { $0.providerID == .lrcapi && !$0.lyrics.lines.isEmpty && !$0.lyrics.isTimeSynced } ?? false)
                for id in actual {
                    XCTAssertTrue(events.contains { $0.phase == .candidateAccepted && $0.provider == .lrcapi && $0.recordID == id })
                    XCTAssertFalse(events.contains { $0.phase == .candidateDropped && $0.recordID == id })
                }
                // A 306.207-second recording must stay plain for the 299-second MV.
                XCTAssertFalse(result?.isTimeSynced ?? true)
            } else {
                XCTAssertEqual(c.failure_reasons["cancelled"], 1, "Phone cancellation is not a completed availability miss")
                XCTAssertTrue(records.isEmpty, "No correct provider record was captured for this cancelled phone lookup")
            }
            report.append(["songID": c.songID, "sourceBuild": 21, "originalTitle": c.original.title,
                "phoneDerivedTitle": c.derived.title, "repairedTitle": metadata.pair.title,
                "repairedArtist": metadata.pair.artist, "phoneFailureReasons": c.failure_reasons,
                "queries": requested, "phoneRejectedRecordIDs": c.correct_artist_candidates_rejected.map(\.recordID),
                "acceptedRecordIDs": result?.candidates.map(\.recordID) ?? [],
                "liveAvailabilityVerified": false, "syntheticLyricContent": true,
                "trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "phone-build21-title-query-record-regression"; attachment.lifetime = .keepAlways; add(attachment)
        print("PHONE_BUILD21_REGRESSION " + String(decoding: data, as: UTF8.self))
    }

    func testBoundedDisplayRolesPreserveFormalTitlesVersionsAndGuestIdentity() throws {
        for track in ["Song Live", "Song Remix", "Song Acoustic", "Song (Live Official MV)", "Song [Live Lyric Video]"] {
            let context = LyricsLookupContext(title: "Singer《" + track + "》【電視劇《Work》插曲】Official MV", artist: "", hasYouTubeOrigin: true)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            XCTAssertEqual(metadata.pair.title, track)
            XCTAssertEqual(metadata.pair.artist, "Singer")
            XCTAssertEqual(metadata.versionTags, LyricsCanonicalMetadata.versions(track))
        }
        for preserved in ["Song (OST)", "Song【Live OST】", "Song (Remix Official MV)", "Song Unofficial MV"] {
            XCTAssertEqual(LyricsLookupMetadata.strippingVideoPresentation(preserved), preserved)
        }
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(.init(title: "Singer《Song Live》", artist: "", hasYouTubeOrigin: true)))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "Song", artist: "Singer"), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "Song Live", artist: "Different singer"), metadata: metadata))
        XCTAssertEqual(LyricsCandidateScorer.rejectionReason(candidate(title: "Wrong song", artist: "Different singer"), metadata: metadata), .primaryPerformerMismatch)
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "Song Live", artist: "Singer & Guest"), metadata: metadata))
        XCTAssertEqual(LyricsLookupMetadata.cleaned(title: "Singer《Song》 Part Two", artist: "", allowVideoCredits: true)?.title, "Song Part Two")
    }

    func testUploaderIsRetainedForDisplayButUnknownForBareTitleLyrics() throws {
        var song = Song(id: "video000001", title: "Bare title", artistName: "Real singer name", artistId: nil,
            albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil, artistNameSource: .uploader)
        let context = LyricsLookupContext(song: song)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(context.artist, "Real singer name")
        XCTAssertEqual(context.artistNameSource, .uploader)
        XCTAssertEqual(metadata.pair.artist, "")
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).allSatisfy { $0.endpoint == "search" && $0.pair.artist.isEmpty })
        let suite = "uploader-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([candidate(title: "Bare title", artist: "Another performer")], metadata: metadata, defaults: defaults))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertTrue(result.lines.isEmpty, "Unknown artist must remain a manual choice")
        song.artistNameSource = .artistMetadata
        XCTAssertEqual(LyricsCanonicalMetadata(LyricsLookupContext(song: song))?.pair.artist, "Real singer name")
        song.artistNameSource = nil
        XCTAssertEqual(LyricsCanonicalMetadata(LyricsLookupContext(song: song))?.pair.artist, "Real singer name", "Do not reinterpret legacy artist metadata")
    }

    func testExplicitCreditOverridesUploaderAndProvenanceRoundTripsWithoutBreakingLegacySongs() throws {
        let song = Song(id: "video000002", title: "Singer《Song》 Official MV", artistName: "Upload channel", artistId: nil,
            albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil, artistNameSource: .uploader)
        let context = LyricsLookupContext(song: song)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        XCTAssertEqual(metadata.pair.artist, "Singer")
        XCTAssertEqual(metadata.pair.title, "Song")
        XCTAssertEqual(context.artist, "Upload channel")
        XCTAssertTrue(LyricsQueryPlanner.queries(metadata).allSatisfy { $0.pair.artist != "Upload channel" })
        XCTAssertEqual(try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song)).artistNameSource, .uploader)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
        legacy.removeValue(forKey: "artistNameSource")
        let decoded = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.artistNameSource)
        XCTAssertEqual(decoded.artistName, "Upload channel")
        let event = LyricsLookupDiagnostics.Event(context: context, phase: .lookup)
        XCTAssertEqual(event.artistNameSource, .uploader)
    }

    private func candidate(title: String, artist: String) -> LyricsCandidate {
        .init(id: .init(providerID: .lrcapi, recordID: "fixture"), title: title, artist: artist, duration: nil,
            lyrics: SyncedLyrics(lines: [.init(time: 0, text: "Synthetic line")], source: "LrcApi", isTimeSynced: false, providerID: .lrcapi))
    }
}

private final class PhoneLyricsProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var routes = Set<String>(), payload = Data(), requests: [String] = []
    static func configure(routes: Set<String>, records: Data) {
        lock.lock(); defer { lock.unlock() }; self.routes = routes; payload = records; requests = []
    }
    static func queries() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let primary = url.host == "lrclib.net" && url.path == "/api/search"
        let secondary = url.host == "api.lrc.cx" && url.path == "/jsonapi"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let title = items.first { $0.name == (primary ? "track_name" : "title") }?.value ?? ""
        let artist = items.first { $0.name == (primary ? "artist_name" : "artist") }?.value ?? ""
        let key = title + "|" + artist
        Self.lock.lock()
        Self.requests.append((primary ? "lrclib" : secondary ? "lrcapi" : "unknown") + "|" + key)
        let data = secondary && Self.routes.contains(key) ? Self.payload : Data("[]".utf8)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: primary || secondary ? 200 : 404,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
