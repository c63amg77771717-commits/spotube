import Foundation
import XCTest
@testable import LovelyMusic

final class ChineseLyricsLookupTests: XCTestCase {
    func testBilingualChineseVideoCreditsReachTheMatchingChineseRecording() async throws {
        await ChineseLyricsRequests.shared.reset()
        let title = "測試歌手 Alice - 晨光旋律 Morning Tune (Official Music Video)"
        let result = try await lyrics(title: title, artist: "測試歌手 Alice", duration: 247)
        XCTAssertEqual(result?.lines.first?.text, "Chinese fixture")
        let pairs = await ChineseLyricsRequests.shared.pairs
        XCTAssertEqual(pairs.last, "測試歌手|晨光旋律")
        XCTAssertLessThanOrEqual(pairs.count, 4, "Fallback remains bounded, including the durationless exact retry")
        XCTAssertEqual(title, "測試歌手 Alice - 晨光旋律 Morning Tune (Official Music Video)")
    }

    func testChineseSongBracketsAndEmptyArtistUseExplicitSingleVideoCredit() async throws {
        for title in ["測試歌手 Alice【晨光旋律】Official MV", "測試歌手 Alice《晨光旋律》Official MV"] {
            await ChineseLyricsRequests.shared.reset()
            let result = try await lyrics(title: title, artist: "", duration: 247)
            XCTAssertEqual(result?.lines.first?.text, "Chinese fixture")
            let pairs = await ChineseLyricsRequests.shared.pairs
            XCTAssertEqual(pairs.last, "測試歌手|晨光旋律")
        }
    }

    func testChineseArtistAliasWithAnAlreadyCleanTitleWorksWithoutChangingCatalogRules() async throws {
        await ChineseLyricsRequests.shared.reset()
        let matched = try await lyrics(title: "夜色旋律", artist: "範例歌手 Benny", duration: 247)
        XCTAssertNotNil(matched)
        let pairs = await ChineseLyricsRequests.shared.pairs
        XCTAssertEqual(pairs.last, "範例歌手|夜色旋律")
        await ChineseLyricsRequests.shared.reset()
        let catalog = try await lyrics(title: "夜色旋律", artist: "範例歌手 Benny", duration: nil, video: false)
        XCTAssertNil(catalog)
        let catalogPairs = await ChineseLyricsRequests.shared.pairs
        XCTAssertEqual(catalogPairs, ["範例歌手 Benny|夜色旋律"])
    }

    func testVersionAndGuestCreditsCannotBeReducedToAnotherChineseRecording() {
        for version in ["Live", "Remix", "Acoustic", "Cover", "Remastered", "Sped Up"] {
            XCTAssertNil(LyricsLookupMetadata.chineseVideoPair(
                title: "晨光旋律 \(version)", artist: "測試歌手 Alice", allowVideoCredits: true))
        }
        XCTAssertNil(LyricsLookupMetadata.chineseVideoPair(
            title: "晨光旋律 Morning Tune", artist: "測試歌手 Alice & Guest", allowVideoCredits: true))
    }

    func testChineseFallbackRejectsAnotherArtistAndDowngradesDurationMismatch() async throws {
        let wrongArtist = try await lyrics(title: "錯誤歌手", artist: "測試歌手 Alice", duration: 247)
        let wrongDuration = try await lyrics(title: "錯誤長度", artist: "測試歌手 Alice", duration: 247)
        XCTAssertNil(wrongArtist)
        XCTAssertNotNil(wrongDuration)
        XCTAssertEqual(wrongDuration?.isTimeSynced, false)
    }

    private func lyrics(title: String, artist: String, duration: Int?, video: Bool = true) async throws -> SyncedLyrics? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChineseLyricsFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await LrcLibService(session: session).getLyrics(
            title: title, artist: artist, duration: duration, allowVideoCredits: video)
    }
}

private actor ChineseLyricsRequests {
    static let shared = ChineseLyricsRequests()
    var pairs: [String] = []
    func reset() { pairs = [] }
    func append(_ pair: String) { pairs.append(pair) }
}

private final class ChineseLyricsFixture: URLProtocol {
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        responseTask = Task {
            let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let title = values.first { $0.name == "track_name" }!.value!
            let artist = values.first { $0.name == "artist_name" }!.value!
            await ChineseLyricsRequests.shared.append("\(artist)|\(title)")
            guard !Task.isCancelled else { return }
            let match = ["測試歌手", "範例歌手"].contains(artist)
                && ["晨光旋律", "夜色旋律", "錯誤歌手", "錯誤長度"].contains(title)
            let response = HTTPURLResponse(url: request.url!, statusCode: match ? 200 : 404,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if match {
                let json: [String: Any] = ["trackName": title,
                    "artistName": title == "錯誤歌手" ? "其他歌手" : artist,
                    "duration": title == "錯誤長度" ? 400.0 : 247.0,
                    "syncedLyrics": "[00:01.00]Chinese fixture"]
                client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
