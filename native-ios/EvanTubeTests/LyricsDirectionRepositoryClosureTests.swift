import Foundation
import XCTest
@testable import LovelyMusic

/// URLProtocol intercepts every request. Both adapters and the composite compute
/// their own coverage from these responses; no coverage is injected by the tests.
final class LyricsDirectionRepositoryClosureTests: XCTestCase {
    private func withSources(_ mode: String, title: String = "Performer - Track (Lyrics) ft. Guest",
                             body: (LrcLibService, CompositeLyricsRepository, LyricsLookupContext) async throws -> Void) async throws {
        DirectionClosureHTTP.configure(mode)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectionClosureHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let suite = "DirectionRepositoryClosure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = LrcLibService(session: session, defaults: defaults)
        let secondary = LrcApiService(session: session, defaults: defaults, retryTransient: false)
        let composite = CompositeLyricsRepository(primary: primary, secondary: secondary,
            defaults: defaults, secondaryEnabled: { true })
        let context = LyricsLookupContext(title: title, artist: "", duration: 200, hasYouTubeOrigin: true)
        try await body(primary, composite, context)
    }

    func testActualCompositeCompletesBothProvidersBeforeAutomaticSelection() async throws {
        try await withSources("complete") { _, composite, context in
            let report = try await composite.lookup(context: context)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let evidence = try XCTUnwrap(report.directionEvidence)
            XCTAssertEqual(report.state, .synchronized)
            XCTAssertEqual(report.lyrics?.lines.map(\.text), ["Synthetic line", "Second synthetic line"])
            XCTAssertEqual(evidence.coverage.count, 2)
            XCTAssertTrue(evidence.coverage.allSatisfy { $0.covers(LyricsDirectionPolicy.requiredPairs(metadata)) })
            XCTAssertFalse(LyricsDirectionPolicy.confirmedHypothesisIDs(evidence.candidates,
                metadata: metadata, coverage: evidence.coverage).isEmpty)
            XCTAssertTrue(report.lyrics?.candidates.allSatisfy { $0.identityDecision?.kind == .confirmed } ?? false)
            for host in ["lrclib.net", "api.lrc.cx"] {
                XCTAssertTrue(DirectionClosureHTTP.requests.contains { $0.host == host && $0.title == "Track" })
                XCTAssertTrue(DirectionClosureHTTP.requests.contains { $0.host == host && $0.title == "Performer" })
            }
        }
    }

    func testActualCompositeSecondaryReverseTimeoutCannotBorrowPrimaryCoverage() async throws {
        try await withSources("secondary-reverse-timeout") { _, composite, context in
            let report = try await composite.lookup(context: context)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let evidence = try XCTUnwrap(report.directionEvidence)
            XCTAssertEqual(report.state, .manualSelection)
            XCTAssertTrue(report.lyrics?.lines.isEmpty ?? false)
            XCTAssertEqual(evidence.coverage.count, 2)
            XCTAssertTrue(evidence.coverage[0].covers(LyricsDirectionPolicy.requiredPairs(metadata)))
            XCTAssertFalse(evidence.coverage[1].covers(LyricsDirectionPolicy.requiredPairs(metadata)))
            XCTAssertTrue(report.failures.contains { $0.providerID == .lrcapi })
            XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs(evidence.candidates,
                metadata: metadata, coverage: evidence.coverage).isEmpty)
            XCTAssertTrue(DirectionClosureHTTP.requests.contains { $0.host == "api.lrc.cx" && $0.title == "Performer" })
        }
    }

    func testActualRepositoryBudgetLeavesUnqueriedDirectionUnconfirmed() async throws {
        let title = "甲乙 Artist - 甲歌 Track『這是一段足夠長的歌詞示例片段，不能擅自認成歌曲別名』【動態歌詞】"
        try await withSources("budget", title: title) { primary, _, context in
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            let required = LyricsDirectionPolicy.requiredPairs(metadata)
            let planned = LyricsQueryPlanner.queries(metadata)
            XCTAssertGreaterThan(required.count, planned.count)
            let report = try await primary.lookup(context: context)
            let evidence = try XCTUnwrap(report.directionEvidence)
            XCTAssertEqual(DirectionClosureHTTP.requests.count, planned.count)
            XCTAssertLessThanOrEqual(DirectionClosureHTTP.requests.count, 6)
            XCTAssertTrue(report.failures.isEmpty, "Budget omission must be tested without a transport failure")
            XCTAssertFalse(evidence.candidates.isEmpty, "An otherwise usable forward record must reach selection")
            XCTAssertEqual(report.state, .manualSelection)
            XCTAssertTrue(report.lyrics?.lines.isEmpty ?? false)
            XCTAssertFalse(evidence.coverage.allSatisfy { $0.covers(required) })
            XCTAssertTrue(LyricsDirectionPolicy.confirmedHypothesisIDs(evidence.candidates,
                metadata: metadata, coverage: evidence.coverage).isEmpty)
        }
    }
}

private final class DirectionClosureHTTP: URLProtocol {
    struct Observed { let host: String; let title: String }
    private static let lock = NSLock()
    private static var mode = "complete"
    private static var observed: [Observed] = []
    static func configure(_ value: String) { lock.withLock { mode = value; observed = [] } }
    static var requests: [Observed] { lock.withLock { observed } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              (host == "lrclib.net" && url.lastPathComponent == "search")
                || (host == "api.lrc.cx" && url.lastPathComponent == "jsonapi") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let title = components.queryItems?.first { $0.name == (host == "lrclib.net" ? "track_name" : "title") }?.value ?? ""
        let mode = Self.lock.withLock { Self.observed.append(.init(host: host, title: title)); return Self.mode }
        if mode == "secondary-reverse-timeout", host == "api.lrc.cx", title == "Performer" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let recordTitle = mode == "budget" ? "甲歌" : "Track"
        let recordArtist = mode == "budget" ? "甲乙 Artist" : "Performer feat. Guest"
        let forward = mode == "budget" ? title.contains("甲歌") : title == "Track"
        let lrc = "[00:01.00]Synthetic line\n[00:02.00]Second synthetic line"
        let record: [String: Any] = host == "lrclib.net"
            ? ["id": 1, "trackName": recordTitle, "artistName": recordArtist,
               "albumName": "Synthetic Album", "duration": 200, "syncedLyrics": lrc]
            : ["id": "one", "title": recordTitle, "artist": recordArtist,
               "album": "Synthetic Album", "duration": 200, "lrc": lrc]
        let records = forward ? [record] : []
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: records))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
