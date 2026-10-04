import XCTest
@testable import LovelyMusic

final class LyricsHTTPFailureTests: XCTestCase {
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
        } catch { XCTAssertTrue(error is URLError) }
    }
}
private final class LyricsHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let missing = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "track_name" })?.value == "missing"
        let response = HTTPURLResponse(url: request.url!, statusCode: missing ? 404 : 503,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
