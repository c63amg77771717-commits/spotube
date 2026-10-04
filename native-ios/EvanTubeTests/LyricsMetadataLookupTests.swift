import XCTest
@testable import LovelyMusic

final class LyricsMetadataLookupTests: XCTestCase {
    private func lyrics(_ title: String, artist: String = "Rick Astley") async throws -> SyncedLyrics? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMetadataFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await LrcLibService(session: session).getLyrics(title: title, artist: artist, duration: nil)
    }
    func testExactArtistPrefixAndOfficialSuffixProduceOneMatchingLookup() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Never Gonna Give You Up Official MV")
        XCTAssertEqual(result?.lines.first?.text, "Matched fixture")
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests, ["Rick Astley|Rick Astley - Never Gonna Give You Up Official MV", "Rick Astley|Never Gonna Give You Up"])
    }
    func testExplicitSinglePerformerCreditWorksWhenArtistIsAnUploader() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Never Gonna Give You Up Official MV (官方頻道)", artist: "Uploader")
        XCTAssertEqual(result?.lines.first?.text, "Matched fixture")
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests.last, "Rick Astley|Never Gonna Give You Up")
        XCTAssertEqual(requests.count, 2)
    }
    func testPresentationRemovalKeepsRemixVersionAndOriginalSongMetadata() async throws {
        let song = Song(id: "AAAAAAAAAAA", title: "Rick Astley - Song Remix (Official Music Video)", artistName: "Rick Astley", artistId: nil, albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
        let result = try await lyrics(song.title, artist: song.artistName)
        XCTAssertEqual(result?.lines.first?.text, "Matched fixture")
        XCTAssertEqual(song.title, "Rick Astley - Song Remix (Official Music Video)")
        XCTAssertEqual(song.artistName, "Rick Astley")
    }
    func testAmbiguousMultipleSeparatorsAndGuestCreditsDoNotGenerateAnotherPair() async throws {
        for title in ["Rick Astley - Song - Live Official MV", "Rick Astley & Guest - Song Official MV", "Rick Astley feat Guest - Song Official MV", "Rick Astley with Guest - Song Official MV", "Rick Astley / Guest - Song Official MV"] {
            await LyricsMetadataRequests.shared.reset()
            let result = try await lyrics(title, artist: "Uploader")
            XCTAssertNil(result)
            let requests = await LyricsMetadataRequests.shared.pairs
            XCTAssertEqual(requests.count, 1, "Ambiguous credit cannot be guessed: \(title)")
        }
    }
    func testRelaxedLookupRejectsResponseThatDropsTheRequestedLiveVersion() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Song Live Official MV")
        XCTAssertNil(result)
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests.last, "Rick Astley|Song Live", "The request itself must preserve Live")
    }
    func testRelaxedLookupRejectsAnotherPerformer() async throws {
        let result = try await lyrics("Rick Astley - Wrong Artist Official MV")
        XCTAssertNil(result)
    }
}

private actor LyricsMetadataRequests {
    static let shared = LyricsMetadataRequests()
    var pairs: [String] = []
    func reset() { pairs = [] }
    func append(_ value: String) { pairs.append(value) }
}
private final class LyricsMetadataFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var responseTask: Task<Void, Never>?
    override func startLoading() {
        responseTask = Task {
            let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let title = values.first { $0.name == "track_name" }!.value!
            let artist = values.first { $0.name == "artist_name" }!.value!
            await LyricsMetadataRequests.shared.append("\(artist)|\(title)")
            let match = artist == "Rick Astley" && ["Never Gonna Give You Up", "Song Remix", "Song Live", "Wrong Artist"].contains(title)
            let response = HTTPURLResponse(url: request.url!, statusCode: match ? 200 : 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if match {
                let json: [String: String] = ["trackName": title == "Song Live" ? "Song" : title,
                    "artistName": title == "Wrong Artist" ? "Another Performer" : artist, "plainLyrics": "Matched fixture"]
                client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
