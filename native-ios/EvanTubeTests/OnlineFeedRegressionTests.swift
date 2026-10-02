import XCTest
@testable import LovelyMusic

final class OnlineFeedRegressionTests: XCTestCase {
    func testValidEmptyChartIsAnEmptyFeed() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "YY")
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testMalformedChartResponseIsASourceErrorRatherThanAnEmptyFeed() async {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        do {
            _ = try await EvanTubeOnlineFeedService.chart(region: "ZZ")
            XCTFail("A missing feed/results schema must be reported as a source error, not no songs")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testChartKeepsCatalogIdentitySeparateFromYouTubePlaybackIdentity() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "XX")
        XCTAssertEqual(feed.items.first?.id, "1234567890")
        XCTAssertEqual(feed.items.first?.title, "Fixture track")
        XCTAssertEqual(feed.sourceName, "Apple Music · XX")
    }

    func testChartLookupUsesOfficialYouTubeRouteAndKeepsPlayableVideoIdentity() async throws {
        let keyStore = YouTubeSearchKeyStore(service: "EvanTube.chart-fixture.\(UUID())")
        defer { try? keyStore.remove() }
        try keyStore.save("fixture-key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartSearchResponseProtocol.self]
        let useCase = SearchMusicUseCase(
            repository: InnerTubeRepository(api: InnerTubeAPI()),
            youtubeService: YouTubeSearchService(session: URLSession(configuration: configuration)),
            youtubeKeyStore: keyStore
        )
        let item = EvanTubeOnlineItem(id: "1234567890", title: "Fixture Track", artist: "Fixture Artist",
                                      artworkURL: nil, kind: .song, releaseDate: nil)
        let result = try await useCase.executeOnline(query: "\(item.title) \(item.artist)", filter: .songs)
        let song = try XCTUnwrap(result.songs.first)
        XCTAssertEqual(song.id, "4DARsEmUxMg", "Pass the resolved YouTube video ID, never the chart catalog ID")
        XCTAssertNotEqual(song.id, item.id)
        XCTAssertTrue(song.hasYouTubeOrigin)
        XCTAssertTrue(song.title.contains(item.artist), "Official videos can identify the artist in the title")
        XCTAssertEqual(song.artistName, "Universal Music Canada", "The YouTube channel need not equal the chart artist")
    }
}

private final class ChartSearchResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "q" }?.value
        let validRoute = url.host == "www.googleapis.com" && url.path == "/youtube/v3/search"
            && query == "Fixture Track Fixture Artist"
        let json = validRoute
            ? #"{"items":[{"id":{"videoId":"4DARsEmUxMg"},"snippet":{"title":"Fixture Artist - Fixture Track (Official Video)","channelTitle":"Universal Music Canada","thumbnails":{}}}]}"#
            : #"{"items":[]}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OnlineFeedResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, url.host == "rss.applemarketingtools.com" else { return false }
        return ["xx", "yy", "zz"].contains { url.path.contains("/\($0)/") }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let json: String
        if url.path.contains("/zz/") {
            json = #"{"unexpected":[]}"#
        } else if url.path.contains("/yy/") {
            json = #"{"feed":{"results":[]}}"#
        } else {
            // Synthetic transport fixture; this is never a production catalog.
            json = #"{"feed":{"results":[{"id":"1234567890","name":"Fixture track","artistName":"Fixture artist"}]}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
