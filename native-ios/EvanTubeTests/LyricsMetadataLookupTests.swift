import XCTest
@testable import LovelyMusic

final class LyricsMetadataLookupTests: XCTestCase {
    func testVerifiedVideoUnicodeAndBracketedCreditsProduceExactMatchingLyrics() async throws {
        for title in ["Rick Astley – Never Gonna Give You Up (Official Video)",
                      "Rick Astley《Never Gonna Give You Up》 Official Audio"] {
            await LyricsMetadataRequests.shared.reset()
            let result = try await lyrics(title, artist: "")
            XCTAssertEqual(result?.lines.first?.text, "Matched fixture")
            let requests = await LyricsMetadataRequests.shared.pairs
            XCTAssertEqual(requests, ["Rick Astley|Never Gonna Give You Up"])
        }
        XCTAssertNil(LyricsLookupMetadata.cleaned(title: "Rick Astley & Guest《Song》", artist: "", allowVideoCredits: true))
        let live = LyricsLookupMetadata.cleaned(title: "Rick Astley《Song Live》 (Official Video)", artist: "", allowVideoCredits: true)
        XCTAssertEqual(live?.title, "Song Live")
    }

    func testVerifiedVideoEmptyArtistUsesSingleCreditBeforeInvalidRequest() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Never Gonna Give You Up", artist: "  ")
        XCTAssertEqual(result?.lines.first?.text, "Matched fixture")
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests, ["Rick Astley|Never Gonna Give You Up"])
    }
    func testEmptyArtistAmbiguousOrCatalogMetadataDoesNotSendInvalidRequest() async throws {
        for (title, video) in [("Rick Astley - Never Gonna Give You Up", false), ("Rick Astley & Guest - Song", true), ("Rick Astley - Song - Live", true), ("Song", true)] {
            await LyricsMetadataRequests.shared.reset()
            let result = try await lyrics(title, artist: "", allowVideoCredits: video)
            XCTAssertNil(result)
            let requests = await LyricsMetadataRequests.shared.pairs
            XCTAssertTrue(requests.isEmpty)
        }
    }
    func testEmptyArtistExtractedPairStillRequiresResponseIdentity() async throws {
        for title in ["Wrong Artist", "Song Live", "Missing Identity"] {
            let result = try await lyrics("Rick Astley - \(title)", artist: "")
            XCTAssertNil(result)
        }
    }
    private func lyrics(_ title: String, artist: String = "Rick Astley", allowVideoCredits: Bool = true, duration: Int? = nil) async throws -> SyncedLyrics? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMetadataFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await LrcLibService(session: session).getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: allowVideoCredits)
    }
    func testExactArtistPrefixAndOfficialSuffixProduceOneMatchingLookup() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Never Gonna Give You Up Official MV", allowVideoCredits: false)
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
    func testCatalogMetadataCannotReplaceArtistFromTheTitle() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Rick Astley - Never Gonna Give You Up Official MV", artist: "Catalog Artist", allowVideoCredits: false)
        XCTAssertNil(result)
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests, ["Catalog Artist|Rick Astley - Never Gonna Give You Up Official MV"])
    }
    func testUnofficialAndMixedVersionBracketsRemainComplete() async throws {
        for preserved in ["Song Unofficial MV", "Song Unofficial Music Video", "Song (Remix Official MV)", "Song [Live Lyric Video]", "Song 【Acoustic Music Video】"] {
            await LyricsMetadataRequests.shared.reset()
            let result = try await lyrics("Rick Astley - \(preserved)")
            XCTAssertNil(result)
            let requests = await LyricsMetadataRequests.shared.pairs
            XCTAssertEqual(requests.last, "Rick Astley|\(preserved)", "Only an entire independent presentation suffix may be removed")
        }
    }
    func testDurationlessResponseStillMustKeepRequestedArtistVersionAndIdentity() async throws {
        for title in ["Wrong Artist", "Song Live", "Missing Identity"] {
            let result = try await lyrics(title, allowVideoCredits: false, duration: 240)
            XCTAssertNil(result, "A durationless retry cannot display another recording or unidentified lyrics: \(title)")
        }
    }
    func testCatalogPresentationWordsAreNotGuessedWithoutVideoOriginOrExactArtistCredit() async throws {
        await LyricsMetadataRequests.shared.reset()
        let result = try await lyrics("Never Gonna Give You Up Official MV", allowVideoCredits: false)
        XCTAssertNil(result)
        let requests = await LyricsMetadataRequests.shared.pairs
        XCTAssertEqual(requests.count, 1)
        let verified = try await lyrics("Never Gonna Give You Up Official MV", allowVideoCredits: true)
        XCTAssertEqual(verified?.lines.first?.text, "Matched fixture")
    }
    func testPipeAndVersusCreditsCannotBeGuessedAsASinglePerformer() async throws {
        for credit in ["Rick Astley | Guest", "Rick Astley vs Guest", "Rick Astley versus Guest"] {
            await LyricsMetadataRequests.shared.reset()
            let result = try await lyrics("\(credit) - Never Gonna Give You Up Official MV", artist: "Uploader")
            XCTAssertNil(result)
            let requests = await LyricsMetadataRequests.shared.pairs
            XCTAssertEqual(requests.count, 1)
        }
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
            let hasDuration = values.contains { $0.name == "duration" }
            let match = !hasDuration && artist == "Rick Astley" && ["Never Gonna Give You Up", "Song Remix", "Song Live", "Wrong Artist", "Missing Identity"].contains(title)
            let response = HTTPURLResponse(url: request.url!, statusCode: artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 400 : (match ? 200 : 404), httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if match {
                var json: [String: String] = ["trackName": title == "Song Live" ? "Song" : title,
                    "artistName": title == "Wrong Artist" ? "Another Performer" : artist, "plainLyrics": "Matched fixture"]
                if title == "Missing Identity" { json = ["plainLyrics": "Unidentified fixture"] }
                client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
