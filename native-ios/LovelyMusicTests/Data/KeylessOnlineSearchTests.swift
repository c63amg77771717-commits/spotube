import Foundation
import XCTest
@testable import LovelyMusic

/// Build 32 regression: online music search does not require a user-issued
/// YouTube Data API key or an app-embedded private credential.
final class KeylessOnlineSearchTests: XCTestCase {
    private static let fixtureKey = "AIza" + String(repeating: "A", count: 35)
    private static let fixtureVersion = "1.20261020.01.00"

    func testAnonymousSearchBootstrapParsesYouTubeMusicPage() {
        let html = #"<script>ytcfg.set({"INNERTUBE_API_KEY":"# +
            "\"\(Self.fixtureKey)\"," +
            #""INNERTUBE_CONTEXT_CLIENT_VERSION":"# +
            "\"\(Self.fixtureVersion)\"});</script>"
        let value = PublicMusicWebBootstrap.parse(html)
        XCTAssertEqual(value?.apiKey, Self.fixtureKey)
        XCTAssertEqual(value?.clientVersion, Self.fixtureVersion)
    }

    func testMalformedOrAbsentWebConfigurationFailsClosed() {
        XCTAssertNil(PublicMusicWebBootstrap.parse("<html><script>no ytcfg</script></html>"))
        XCTAssertNil(PublicMusicWebBootstrap.parse(
            #"{"INNERTUBE_API_KEY":"not-an-api-key","INNERTUBE_CONTEXT_CLIENT_VERSION":"1.20261020.01.00"}"#
        ))
        XCTAssertNil(PublicMusicWebBootstrap.parse(
            "{\"INNERTUBE_API_KEY\":\"\(Self.fixtureKey)\"}"
        ))
    }

    func testOnlineSearchEnabledWithoutCustomDataAPIKey() {
        let useCase = SearchMusicUseCase(repository: InnerTubeRepository(api: InnerTubeAPI()))
        XCTAssertTrue(useCase.isOnlineConfigured,
            "Anonymous YouTube Music search must never be gated on Google Data API credentials")
    }

    func testAnonymousSearchObtainsPublicClientAndPerformsLivePathAgainstFixture() async throws {
        // This test uses ONLY an isolated localhost-free URLProtocol fixture.
        // The production client still fetches the public web bootstrap by HTTPS.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeylessYouTubeMusicProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        KeylessYouTubeMusicProtocol.reset()

        let suite = "keyless-search-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = InnerTubeAPI(session: session, userDefaults: defaults)
        let data = try await api.search(query: "Dax", params: nil)
        XCTAssertFalse(data.isEmpty)
        let sent = KeylessYouTubeMusicProtocol.searchRequest()
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"),
                       Self.fixtureVersion)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "music.youtube.com")
        let keyParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value
        XCTAssertEqual(keyParam, Self.fixtureKey)
    }
}

/// No credential is sent to any real service in these tests.
/// Responds to sw.js_data, homepage bootstrap and youtubei/v1/search.
private final class KeylessYouTubeMusicProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var lastSearchRequest: URLRequest?

    static func reset() {
        lock.lock()
        lastSearchRequest = nil
        lock.unlock()
    }

    static func searchRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastSearchRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "music.youtube.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        let payload: String
        let status: Int
        let mime: String
        if path == "/" {
            status = 200
            mime = "text/html"
            payload = #"<script>ytcfg.set({"INNERTUBE_API_KEY":"# +
                "\"AIza\(String(repeating: "A", count: 35))\"," +
                #""INNERTUBE_CONTEXT_CLIENT_VERSION":"1.20261020.01.00"});</script>"#
        } else if path == "/youtubei/v1/search" {
            status = 200
            mime = "application/json"
            payload = #"{"contents":{"sectionListRenderer":{"contents":[]}}}"#
            Self.lock.lock()
            Self.lastSearchRequest = request
            Self.lock.unlock()
        } else {
            status = 404
            mime = "application/json"
            payload = "{}"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
