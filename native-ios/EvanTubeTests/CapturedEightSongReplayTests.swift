import XCTest
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
        for c in fixture.cases {
            let primary = try JSONEncoder().encode(c.responses["LRCLib"]!)
            let secondary = try JSONEncoder().encode(c.responses["LrcApi"]!)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CapturedReplayProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            CapturedReplayProtocol.set(primary: primary, secondary: secondary)
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
            CapturedReplayProtocol.set(primary: primary, secondary: secondary)
            let context = LyricsLookupContext(songID: c.songID, title: c.title, artist: c.artist,
                album: nil, duration: c.duration, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil)
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
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == context.diagnosticLookupID }
            XCTAssertFalse(events.contains { $0.reason == .schema || $0.reason == .network }, c.songID)
            func describe(_ value: SyncedLyrics?) -> [String: Any] {
                ["hasResult": value != nil, "lineCount": value?.lines.count ?? 0,
                 "timeSynced": value?.isTimeSynced ?? false,
                 "candidateIDs": value?.candidates.map { $0.providerID.rawValue + ":" + $0.recordID } ?? []]
            }
            report.append(["songID": c.songID, "before": describe(before), "after": describe(after),
                "beforeQueries": beforeQueries, "afterQueries": CapturedReplayProtocol.queries(),
                "capturedPrimaryCount": c.responses["LRCLib"]!.count, "capturedSecondaryCount": c.responses["LrcApi"]!.count,
                "canonicalPair": LyricsCanonicalMetadata(context).map { ["title": $0.pair.title, "artist": $0.pair.artist] } ?? [:],
                "afterTrace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "captured-eight-before-after-metadata-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("CAPTURED_EIGHT_REPLAY " + String(decoding: data, as: UTF8.self))
    }
}

private final class CapturedReplayProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var primary = Data(), secondary = Data(), requests: [String] = []
    static func set(primary: Data, secondary: Data) {
        lock.lock(); defer { lock.unlock() }
        self.primary = primary; self.secondary = secondary; requests = []
    }
    static func queries() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let isSearch = url.lastPathComponent == "search" || url.lastPathComponent == "jsonapi"
        Self.lock.lock()
        Self.requests.append(url.absoluteString)
        let data = isSearch ? (url.host == "lrclib.net" ? Self.primary : Self.secondary) : Data()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: isSearch ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
