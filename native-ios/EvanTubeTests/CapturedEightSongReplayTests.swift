import XCTest
import ZIPFoundation
@testable import LovelyMusic

final class CapturedEightSongReplayTests: XCTestCase {
    struct Fixture: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let songID, title, artist: String
        let duration: Int
        let capturePair: [String: String]
        let responses: [String: [[String: JSONValue]]]
    }
    enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
    }
    func testSameCapturedEightResponsesBeforeAndAfterRepair() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "captured_eight_lyrics", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 8)
        var report: [[String: Any]] = []
        for titleField in ["title", "title_raw"] {
        for c in fixture.cases {
            let primary = try JSONEncoder().encode(c.responses["LRCLib"]!)
            let secondary = try JSONEncoder().encode(c.responses["LrcApi"]!)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CapturedReplayProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            CapturedReplayProtocol.set(primary: primary, secondary: secondary, pair: c.capturePair)
            let suite = "captured-eight-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let beforeContext = CapturedBuild20LyricsLookupContext(songID: c.songID, title: c.title, artist: c.artist,
                album: nil, duration: c.duration, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil)
            let beforeRepo = CapturedBuild20CompositeLyricsRepository(
                primary: CapturedBuild20LrcLibService(session: session, defaults: defaults),
                secondary: CapturedBuild20LrcApiService(session: session, defaults: defaults), defaults: defaults, secondaryEnabled: { true })
            let before = try await beforeRepo.getLyrics(context: beforeContext)
            let beforeQueries = CapturedReplayProtocol.queries()
            CapturedReplayProtocol.set(primary: primary, secondary: secondary, pair: c.capturePair)
            let context = LyricsLookupContext(song: try importedSong(c, titleField: titleField))
            let afterRepo = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults),
                secondary: LrcApiService(session: session, defaults: defaults), defaults: defaults, secondaryEnabled: { true })
            let after = try await afterRepo.getLyrics(context: context)
            // Actual provider capture contains no correct ycccc recording. A
            // successful decoder must reject unrelated songs, not invent lyrics.
            if c.songID == "3hw92j4SqrI" {
                XCTAssertNil(after, "Both captured providers contain no valid ycccc candidate")
            } else if let result = after {
                XCTAssertFalse(result.candidates.isEmpty, c.songID)
                XCTAssertTrue(!result.lines.isEmpty || !result.candidates.isEmpty, c.songID)
            } else {
                XCTFail("No captured valid candidate survived: " + c.songID)
            }
            XCTAssertEqual(context.title, c.title)
            XCTAssertEqual(context.artist, "")
            XCTAssertTrue(CapturedReplayProtocol.matchedCaptureQuery(), "Formal importer/query must reach the captured pair: " + c.songID)
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == context.diagnosticLookupID }
            XCTAssertFalse(events.contains { $0.reason == .schema || $0.reason == .network }, c.songID)
            func describe(_ value: SyncedLyrics?) -> [String: Any] {
                ["hasResult": value != nil, "lineCount": value?.lines.count ?? 0,
                 "timeSynced": value?.isTimeSynced ?? false,
                 "candidateIDs": value?.candidates.map { $0.providerID.rawValue + ":" + $0.recordID } ?? []]
            }
            report.append(["songID": c.songID, "importTitleField": titleField, "before": describe(before), "after": describe(after),
                "beforeQueries": beforeQueries, "afterQueries": CapturedReplayProtocol.queries(),
                "capturedPrimaryCount": c.responses["LRCLib"]!.count, "capturedSecondaryCount": c.responses["LrcApi"]!.count,
                "canonicalPair": LyricsCanonicalMetadata(context).map { ["title": $0.pair.title, "artist": $0.pair.artist] } ?? [:],
                "afterTrace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))])
        }
        }
        XCTAssertEqual(report.count, 16)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "captured-eight-before-after-metadata-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CAPTURED_EIGHT_REPLAY " + String(decoding: data, as: UTF8.self))
    }
    private func importedSong(_ c: Case, titleField: String) throws -> Song {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("MB3_All_Playlists.json")
        let zipURL = directory.appendingPathComponent(titleField == "title" ? "MB3_Playlists_Complete.zip" : "MB3_Playlists_Export.zip")
        let row: [String: Any] = ["category": "own", "playlist_id": "7", "playlist_name": "Player",
            "youtube_id": c.songID, titleField: c.title, "duration_seconds": c.duration, "order": 1]
        try JSONSerialization.data(withJSONObject: ["songs": [row]]).write(to: jsonURL)
        try FileManager.default.zipItem(at: jsonURL, to: zipURL, shouldKeepParent: false)
        let parsed = try MB3PlaylistImporter.parse(zipURL: zipURL)
        return try XCTUnwrap(parsed.playlists.first?.songs.first)
    }

    func testUncapturedQueryNeverReceivesCapturedCandidates() async throws {
        let payload = Data(#"[{"id":1,"trackName":"Captured","artistName":"Singer","plainLyrics":"Fixture"}]"#.utf8)
        CapturedReplayProtocol.set(primary: payload, secondary: payload, pair: ["track_name": "Captured", "artist_name": "Singer"])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CapturedReplayProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for url in ["https://lrclib.net/api/search?track_name=Unknown&artist_name=Singer",
                    "https://api.lrc.cx/jsonapi?title=Unknown&artist=Singer"] {
            let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: url)))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[]")
        }
        XCTAssertFalse(CapturedReplayProtocol.matchedCaptureQuery())
    }
}

private final class CapturedReplayProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var primary = Data(), secondary = Data(), requests: [String] = []
    private static var pair: [String: String] = [:], matched = false
    static func set(primary: Data, secondary: Data, pair: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        self.primary = primary; self.secondary = secondary; self.pair = pair; requests = []; matched = false
    }
    static func queries() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    static func matchedCaptureQuery() -> Bool { lock.lock(); defer { lock.unlock() }; return matched }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let primaryRoute = url.host == "lrclib.net" && url.path == "/api/search"
        let secondaryRoute = url.host == "api.lrc.cx" && url.path == "/jsonapi"
        let isSearch = primaryRoute || secondaryRoute
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let title = query.first { $0.name == (primaryRoute ? "track_name" : "title") }?.value
        let artist = query.first { $0.name == (primaryRoute ? "artist_name" : "artist") }?.value
        Self.lock.lock()
        Self.requests.append(url.absoluteString)
        let captured = isSearch && title == Self.pair["track_name"] && artist == Self.pair["artist_name"]
        Self.matched = Self.matched || captured
        let data = captured ? (primaryRoute ? Self.primary : Self.secondary) : isSearch ? Data("[]".utf8) : Data()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: isSearch ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
