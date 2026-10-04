import XCTest
@testable import LovelyMusic

final class LyricsHTTPFailureTests: XCTestCase {
    func testDurationSpecificNotFoundRetriesSamePairWithoutDuration() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let lyrics = try await LrcLibService(session: session).getLyrics(title: "duration-miss", artist: "fixture", duration: 240)
        XCTAssertEqual(lyrics?.lines.first?.text, "Fixture lyrics")
    }
    func testUnknownOrOutOfContractDurationUsesDurationlessLookup() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LrcLibService(session: session)
        for duration in [0, -1, 3601] {
            let lyrics = try await service.getLyrics(title: "duration-contract", artist: "fixture", duration: duration)
            XCTAssertEqual(lyrics?.lines.first?.text, "Fixture lyrics")
        }
    }
    func testMissingLyricsIsEmptyButServerFailureRemainsRetryable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LrcLibService(session: session)
        let missing = try await service.getLyrics(title: "missing", artist: "fixture", duration: nil)
        XCTAssertNil(missing)
        do {
            _ = try await service.getLyrics(title: "unavailable", artist: "fixture", duration: nil)
            XCTFail("HTTP503 is a request failure, not proof that a song has no lyrics")
        } catch {
            guard case PublicSourceError.http("LRCLib", 503) = error else {
                return XCTFail("The actual HTTP503 source/status must remain visible: \(error)")
            }
        }
    }
}
private final class LyricsHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let title = items.first(where: { $0.name == "track_name" })?.value
        let contract = title == "duration-contract"
        let hasDuration = items.contains(where: { $0.name == "duration" })
        let status = contract ? (hasDuration ? 400 : 200) :
            (title == "duration-miss" ? (hasDuration ? 404 : 200) : (title == "missing" ? 404 : 503))
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            let json = ["plainLyrics": "Fixture lyrics", "trackName": title ?? "", "artistName": "fixture"]
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
