import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsPairingAndTimingTests: XCTestCase {
    func testSongAndPerformerAreCheckedIndependentlyEvenOnExactHTTP200() async throws {
        for title in ["wrong-artist", "wrong-title"] {
            let result = try await service().getLyrics(title: title, artist: "Fixture", duration: 240)
            XCTAssertNil(result, "A 200 status is not proof of recording identity")
        }
    }

    func testDurationMismatchUsesTextWithoutManufacturingTimestamps() async throws {
        let result = try await service().getLyrics(title: "duration-diff", artist: "Fixture", duration: 240)
        XCTAssertEqual(result?.lines.map(\.text), ["Fixture line", "Second line"])
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertTrue(result?.lines.allSatisfy { $0.time == 0 } ?? false)
    }

    func testMissingDurationAndInvalidTimestampUsePlainText() async throws {
        for (title, duration) in [("duration-diff", nil as Int?), ("bad-timestamp", 240)] {
            let result = try await service().getLyrics(title: title, artist: "Fixture", duration: duration)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.isTimeSynced, false)
        }
    }

    func testCompatibleDurationCanUseProviderTimestamps() async throws {
        let result = try await service().getLyrics(title: "timed", artist: "Fixture", duration: 240)
        XCTAssertEqual(result?.isTimeSynced, true)
        XCTAssertEqual(result?.lines.first?.time, 1)
    }

    func testDifferentLiveRemixCoverVersionsAndPerformersAreExcludedFromChoices() async throws {
        let result = try await service().getLyrics(title: "choices", artist: "Fixture", duration: 240)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["101", "102"])
        XCTAssertTrue(result?.lines.isEmpty ?? false, "Multiple ambiguous recordings require an explicit choice")
    }

    func testSelectedCandidateIsRememberedForOnlyThisTitleArtistAndVideoDuration() async throws {
        let name = "LyricsSelectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = service(defaults: defaults)
        let response = try await repository.getLyrics(title: "choices", artist: "Fixture", duration: 240)
        let choices = try XCTUnwrap(response)
        let key = try XCTUnwrap(choices.selectionKey)
        LyricsSelectionStore.select(102, for: key, defaults: defaults)
        let remembered = try await repository.getLyrics(title: "choices", artist: "Fixture", duration: 240)
        XCTAssertEqual(remembered?.lines.first?.text, "Second recording")
        XCTAssertEqual(remembered?.isTimeSynced, false)
        let anotherDuration = try await repository.getLyrics(title: "choices", artist: "Fixture", duration: 260)
        XCTAssertTrue(anotherDuration?.lines.isEmpty ?? false)
    }

    func testTraditionalSimplifiedAndPunctuationKeepVersionAndArtistIdentity() {
        XCTAssertEqual(LyricsLookupMetadata.identityKey("測試樂曲"), LyricsLookupMetadata.identityKey("测试乐曲"))
        XCTAssertEqual(LyricsLookupMetadata.identityKey("繁體歌手"), LyricsLookupMetadata.identityKey("繁体歌手"))
        XCTAssertEqual(LyricsLookupMetadata.identityKey("Don't Care"), LyricsLookupMetadata.identityKey("Don’t Care"))
        XCTAssertNotEqual(LyricsLookupMetadata.identityKey("Song (Live)"), LyricsLookupMetadata.identityKey("Song"))
        XCTAssertNotEqual(LyricsLookupMetadata.identityKey("歌手甲"), LyricsLookupMetadata.identityKey("歌手乙"))
        XCTAssertNotEqual(LyricsLookupMetadata.performerKey("Artist A/B"), LyricsLookupMetadata.performerKey("Artist AB"))
    }

    func testMissingPerformerRequiresManualChoiceWithoutSendingEmptyArtistToGet() async throws {
        let result = try await service().getLyrics(title: "choices", artist: "", duration: 240, allowVideoCredits: true)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["101", "102", "106"])
        XCTAssertTrue(result?.lines.isEmpty ?? false, "Even a same-duration candidate cannot establish the missing performer")
    }

    private func service(defaults: UserDefaults = .standard) -> LrcLibService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsPairingFixture.self]
        return LrcLibService(session: URLSession(configuration: config), defaults: defaults)
    }
}

private final class LyricsPairingFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let title = components.queryItems!.first { $0.name == "track_name" }!.value!
        let isSearch = request.url!.lastPathComponent == "search"
        var result: [String: Any] = ["trackName": title, "artistName": "Fixture", "duration": 240.0,
            "syncedLyrics": "[00:01.00]Fixture line\n[00:02.00]Second line"]
        if title == "wrong-artist" { result["artistName"] = "Another performer" }
        if title == "wrong-title" { result["trackName"] = "Another song" }
        if title == "duration-diff" { result["duration"] = 300.0 }
        if title == "bad-timestamp" { result["syncedLyrics"] = "[99:01.00]Fixture line" }
        if title == "choices" { result["id"] = 101; result["duration"] = 200.0 }
        var body: Any = result
        if isSearch {
            var second = result; second["id"] = 102; second["duration"] = 300.0
            second["syncedLyrics"] = "[00:01.00]Second recording"
            var live = result; live["id"] = 103; live["trackName"] = "choices (Live)"
            var remix = result; remix["id"] = 104; remix["trackName"] = "choices (Remix)"
            var cover = result; cover["id"] = 105; cover["trackName"] = "choices (Cover)"
            var other = result; other["id"] = 106; other["artistName"] = "Another performer"
            body = [result, second, live, remix, cover, other]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
