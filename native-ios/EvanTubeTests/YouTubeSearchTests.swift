import XCTest
@testable import LovelyMusic

final class YouTubeSearchTests: XCTestCase {
    func testOfficialSearchKeepsVideoIDsAndPaginationWithoutLeakingTheKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchResponseProtocol.self]
        let service = YouTubeSearchService(session: URLSession(configuration: configuration))
        let result = try await service.search(query: "化身孤島的鯨", key: "test-key")
        XCTAssertEqual(result.songs.map(\.id), ["4DARsEmUxMg"])
        XCTAssertEqual(result.songs.first?.title, "化身孤島的鯨 & 音樂")
        XCTAssertEqual(result.songs.first?.artistNameSource, .uploader)
        XCTAssertEqual(result.songs.first?.artistName, "張靚穎", "Keep display metadata while recording uploader provenance")
        XCTAssertNil(result.songs.first?.artistId, "Channel IDs must not be used as Music browse IDs")
        XCTAssertNil(result.songs.first?.duration, "Unknown duration must not hide search results")
        XCTAssertFalse(result.continuation?.contains("test-key") ?? true)
        let next = try await service.continueSearch(token: try XCTUnwrap(result.continuation), key: "test-key")
        XCTAssertNil(next.continuation)
        XCTAssertEqual(next.songs.map(\.id), ["4DARsEmUxMg"])
    }

    func testQuotaFailureHasAUsefulChineseError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchResponseProtocol.self]
        let service = YouTubeSearchService(session: URLSession(configuration: configuration))
        do {
            _ = try await service.search(query: "quota-check", key: "test-key")
            XCTFail("Quota exhaustion must not be presented as an empty result")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("配額"))
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
        }
    }

    func testKeychainCanSaveReplaceAndRemoveAnIsolatedKey() throws {
        let store = YouTubeSearchKeyStore(service: "EvanTube.search-test.\(UUID())")
        defer { try? store.remove() }
        XCTAssertNil(try store.read())
        try store.save("first-test-key")
        try store.save("replacement-test-key")
        XCTAssertEqual(try store.read(), "replacement-test-key")
        try store.remove()
        XCTAssertNil(try store.read())
    }
}

private final class SearchResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let query = items.first { $0.name == "q" }?.value
        let isNext = items.contains { $0.name == "pageToken" && $0.value == "next-page" }
        let quota = query == "quota-check"
        let json: String
        if quota {
            json = #"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#
        } else {
            let cursor = isNext ? "" : #", "nextPageToken":"next-page""#
            json = #"{"items":[{"id":{"videoId":"4DARsEmUxMg"},"snippet":{"title":"化身孤島的鯨 &amp; 音樂","channelTitle":"張靚穎","channelId":"UC-channel","thumbnails":{}}},{"id":{"channelId":"UC-wrong-kind"},"snippet":{"title":"Channel","channelTitle":"Channel","thumbnails":{}}}]"# + cursor + "}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: quota ? 403 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
