import XCTest
@testable import LovelyMusic

final class OnlineFeedRegressionTests: XCTestCase {
    func testCapturedLiveTaiwanPayloadPassesProductionChartDecoder() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "VV")
        XCTAssertEqual(feed.items.count, 20)
        XCTAssertFalse(feed.items[0].title.isEmpty)
        XCTAssertFalse(feed.items[0].artist.isEmpty)
    }
    func testUnavailableAppleFeedUsesExplicitSameRegionITunesSource() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "RR")
        XCTAssertTrue(feed.sourceName.contains("iTunes"))
        XCTAssertTrue(feed.sourceName.contains("RR"))
        XCTAssertEqual(feed.items.first?.id, "876543210")
        XCTAssertEqual(feed.items.first?.title, "Regional fixture")
    }
    func testMalformedPrimaryStillUsesValidSameRegionFallback() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "QQ")
        XCTAssertTrue(feed.sourceName.contains("iTunes · QQ"))
        XCTAssertEqual(feed.items.first?.title, "Regional fixture")
    }

    func testChartUsesCanonicalAppleHostWithoutLegacyRedirect() async throws {
        URLProtocol.registerClass(OnlineFeedResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OnlineFeedResponseProtocol.self) }
        let feed = try await EvanTubeOnlineFeedService.chart(region: "WW")
        XCTAssertEqual(feed.items.first?.title, "Fixture track")
    }
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
        var sourceSong: Song?
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { query in
            let songs = try await useCase.executeOnline(query: query, filter: .songs).songs
            sourceSong = songs.first
            return songs
        }
        let song = try XCTUnwrap(resolved)
        XCTAssertEqual(song.id, "4DARsEmUxMg", "Pass the resolved YouTube video ID, never the chart catalog ID")
        XCTAssertNotEqual(song.id, item.id)
        XCTAssertTrue(song.hasYouTubeOrigin)
        XCTAssertTrue(sourceSong?.title.contains(item.artist) == true, "Official videos can identify the artist in the title")
        XCTAssertEqual(sourceSong?.artistName, "Universal Music Canada", "The YouTube channel need not equal the chart artist")
        XCTAssertEqual(song.title, item.title)
        XCTAssertEqual(song.artistName, item.artist, "Future preference seeds should use the chart artist rather than a record label")
    }

    func testResolverRejectsWrongArtistAndNonYouTubeIDsBeforeChoosingAPlayableSong() async throws {
        let item = EvanTubeOnlineItem(id: "1234567890", title: "Fixture Track", artist: "Fixture Artist",
                                      artworkURL: nil, kind: .song, releaseDate: nil)
        func song(_ id: String, _ title: String, _ artist: String) -> Song {
            Song(id: id, title: title, artistName: artist, artistId: nil,
                 albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        }
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { _ in [
            song(item.id, item.title, item.artist),
            song("紅紅紅紅紅紅紅紅紅紅紅", item.title, item.artist),
            song("aaaaaaaaaaa", item.title, "Different Artist"),
            song("bbbbbbbbbbb", "Different Track", item.artist),
            song("4DARsEmUxMg", "Fixture Artist - Fixture Track (Official Video)", "Record Label")
        ] }
        XCTAssertEqual(resolved?.id, "4DARsEmUxMg")
    }

    func testResolverMatchesShortChineseTitlesAcrossSimplifiedAndTraditionalScripts() async throws {
        let item = EvanTubeOnlineItem(id: "1234567890", title: "紅豆", artist: "王菲",
                                      artworkURL: nil, kind: .song, releaseDate: nil)
        let candidate = Song(id: "4DARsEmUxMg", title: "王菲 - 红豆 (Official Video)", artistName: "Record Label",
                             artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { _ in [candidate] }
        XCTAssertEqual(resolved?.id, candidate.id)
    }

    func testReleaseCatalogItemNeverEntersSongResolution() async throws {
        let release = EvanTubeOnlineItem(id: "release-id", title: "Album", artist: "Artist",
                                         artworkURL: nil, kind: .release, releaseDate: nil)
        let resolved = try await EvanTubeOnlineSongResolver.resolve(release) { _ in
            XCTFail("An album catalog ID must never reach the song playback resolver")
            return []
        }
        XCTAssertNil(resolved)
    }

    func testResolverAcceptsAnOfficialArtistVEVOChannelWithoutArtistInTheTitle() async throws {
        let item = EvanTubeOnlineItem(id: "1234567890", title: "Fixture Track", artist: "Fixture Artist",
                                      artworkURL: nil, kind: .song, releaseDate: nil)
        let candidate = Song(id: "4DARsEmUxMg", title: "Fixture Track (Official Video)", artistName: "FixtureArtistVEVO",
                             artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item) { _ in [candidate] }
        XCTAssertEqual(resolved?.id, candidate.id)
        XCTAssertEqual(resolved?.artistName, item.artist)
    }

    func testAlbumLookupUsesTheAlbumCapableRepositoryEvenWhenOfficialSearchIsConfigured() async throws {
        let expected = Album(id: "MPREb_fixture_album", title: "Fixture Album", artistName: "Fixture Artist",
                             artistId: nil, year: nil, thumbnailURL: nil, songs: [])
        let repository = MockInnerTubeRepository()
        repository.searchResult = SearchResult(songs: [], albums: [expected], artists: [], playlists: [], continuation: nil)
        let keyStore = YouTubeSearchKeyStore(service: "EvanTube.album-fixture.\(UUID())")
        defer { try? keyStore.remove() }
        try keyStore.save("fixture-key")
        let useCase = SearchMusicUseCase(repository: repository, youtubeKeyStore: keyStore)
        XCTAssertTrue(useCase.isOnlineConfigured)
        let release = EvanTubeOnlineItem(id: "release-id", title: expected.title, artist: "",
                                         artworkURL: nil, kind: .release, releaseDate: nil)
        let resolved = try await EvanTubeOnlineAlbumResolver.resolve(release, searchUseCase: useCase)
        XCTAssertEqual(resolved?.id, expected.id)
        XCTAssertEqual(resolved?.title, expected.title)
        XCTAssertEqual(repository.searchCallCount, 1, "Use the album-capable repository even when official video search is configured")
        XCTAssertEqual(repository.lastSearchFilter, .albums)
    }

    @MainActor func testOverlappingFeedRefreshIgnoresOldResultsAndKeepsNewRequestLoading() async {
        let feeds = EvanTubeHomeFeeds()
        func feed(_ name: String) -> EvanTubeOnlineFeed {
            EvanTubeOnlineFeed(sourceName: name, updatedAt: nil, periodStart: nil, items: [])
        }
        var oldCompletion: CheckedContinuation<EvanTubeOnlineFeed, Never>?
        var newCompletion: CheckedContinuation<EvanTubeOnlineFeed, Never>?
        let older = Task {
            await feeds.refresh(region: "TW", loadChart: { _ in feed("old chart") }, loadWeekly: {
                await withCheckedContinuation { oldCompletion = $0 }
            }, loadReleases: { feed("old releases") })
        }
        let deadline = Date().addingTimeInterval(2)
        while oldCompletion == nil && Date() < deadline { await Task.yield() }
        guard let finishOld = oldCompletion else { older.cancel(); XCTFail("Old request did not begin"); return }
        let newer = Task {
            await feeds.refresh(region: "CA", loadChart: { _ in feed("new chart") }, loadWeekly: {
                await withCheckedContinuation { newCompletion = $0 }
            }, loadReleases: { feed("new releases") })
        }
        let nextDeadline = Date().addingTimeInterval(2)
        while (newCompletion == nil || feeds.chart?.sourceName != "new chart") && Date() < nextDeadline { await Task.yield() }
        guard let finishNew = newCompletion else {
            finishOld.resume(returning: feed("old weekly"))
            older.cancel(); newer.cancel(); XCTFail("New request did not begin"); return
        }
        finishOld.resume(returning: feed("old weekly"))
        await older.value
        XCTAssertTrue(feeds.isLoading, "An older completion must not hide a newer request's spinner")
        XCTAssertEqual(feeds.chart?.sourceName, "new chart", "A fast chart should appear while the community feeds are loading")
        XCTAssertNil(feeds.weekly)
        XCTAssertNil(feeds.releases)
        finishNew.resume(returning: feed("new weekly"))
        await newer.value
        XCTAssertEqual(feeds.chart?.sourceName, "new chart")
        XCTAssertEqual(feeds.weekly?.sourceName, "new weekly")
        XCTAssertEqual(feeds.releases?.sourceName, "new releases")
        XCTAssertFalse(feeds.isLoading)
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
        guard let url = request.url, ["rss.applemarketingtools.com", "rss.marketingtools.apple.com", "itunes.apple.com"].contains(url.host ?? "") else { return false }
        return ["qq", "rr", "vv", "ww", "xx", "yy", "zz"].contains { url.path.contains("/\($0)/") }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.contains("/vv/") {
            let file = Bundle(for: OnlineFeedRegressionTests.self).url(forResource: "apple-tw20-live-20261004", withExtension: "json")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! Data(contentsOf: file))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let json: String
        if url.path.contains("/zz/") {
            json = #"{"unexpected":[]}"#
        } else if url.host == "itunes.apple.com" {
            json = #"{"feed":{"updated":{"label":"2026-10-04T10:00:00Z"},"entry":[{"id":{"attributes":{"im:id":"876543210"}},"im:name":{"label":"Regional fixture"},"im:artist":{"label":"Regional artist"},"im:image":[{"label":"https://example.com/art.png"}]}]}}"#
        } else if url.path.contains("/qq/") {
            json = #"{"unexpected":[]}"#
        } else if url.path.contains("/yy/") {
            json = #"{"feed":{"results":[]}}"#
        } else {
            // Synthetic transport fixture; this is never a production catalog.
            json = #"{"feed":{"results":[{"id":"1234567890","name":"Fixture track","artistName":"Fixture artist"}]}}"#
        }
        let correctRoute = url.host == "rss.marketingtools.apple.com" && url.path == "/api/v2/ww/music/most-played/20/songs.json"
        let unavailable = url.path.contains("/rr/") && url.host != "itunes.apple.com"
        let response = HTTPURLResponse(url: url, statusCode: unavailable || (url.path.contains("/ww/") && !correctRoute) ? 503 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
