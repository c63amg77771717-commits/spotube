import XCTest
@testable import LovelyMusic

final class YouTubeMusicLyricsTests: XCTestCase {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testTimedLinesUseCueStartTimes() throws {
        let response = try json("""
        {"contents":{"timedLyricsData":[
          {"lyricLine":"♪","cueRange":{"startTimeMilliseconds":"0","endTimeMilliseconds":"14924"}},
          {"lyricLine":"空盪盪的右手","cueRange":{"startTimeMilliseconds":"14924","endTimeMilliseconds":"18000"}}
        ]}}
        """)
        let lines = try XCTUnwrap(YouTubeMusicLyricsService.timedLines(response))
        XCTAssertEqual(lines.map(\.text), ["♪", "空盪盪的右手"])
        XCTAssertEqual(lines.map(\.time), [0, 14.924])
    }

    func testLinesWithoutCuesAreNotTimed() throws {
        // Music videos often return the lines with no cueRange at all.
        let response = try json(#"{"timedLyricsData":[{"lyricLine":"坦白來說"},{"lyricLine":"我不知道"}]}"#)
        XCTAssertNil(YouTubeMusicLyricsService.timedLines(response))
    }

    func testPlainTextAndAttribution() throws {
        let response = try json("""
        {"musicDescriptionShelfRenderer":{
          "description":{"runs":[{"text":"第一行\\n\\n第二行"}]},
          "footer":{"runs":[{"text":"來源：LyricFind"}]}}}
        """)
        let plain = try XCTUnwrap(YouTubeMusicLyricsService.plainText(response))
        XCTAssertEqual(plain.text, "第一行\n\n第二行")
        XCTAssertEqual(plain.attribution, "LyricFind")
    }

    private func context() -> LyricsLookupContext {
        LyricsLookupContext(songID: "s-ANFN9yJ1s", title: "Song", artist: "Artist", duration: 246, hasYouTubeOrigin: true)
    }

    private static let timed = SyncedLyrics(lines: [LyricLine(time: 1, text: "a")], source: "YouTube Music",
                                            providerID: .youtubeMusic)
    private static let plain = SyncedLyrics(lines: [LyricLine(time: 0, text: "a")], source: "YouTube Music",
                                            isTimeSynced: false, providerID: .youtubeMusic, timingState: .plainOnly)
    private static let lrclibTimed = SyncedLyrics(lines: [LyricLine(time: 2, text: "b")], source: "LRCLib",
                                                  providerID: .lrclib)

    func testOfficialTimedLyricsSkipTheFallback() async throws {
        let fallback = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.timed }, fallback: fallback)
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .youtubeMusic)
        XCTAssertEqual(report.state, .synchronized)
        XCTAssertEqual(fallback.calls, 0)
    }

    func testFallbackTimelineBeatsOfficialPlainText() async throws {
        let fallback = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.plain }, fallback: fallback)
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)
        XCTAssertEqual(fallback.calls, 1)
    }

    func testOfficialPlainTextBeatsNoFallbackMatch() async throws {
        let fallback = RecordingLyricsRepository(lyrics: nil)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.plain }, fallback: fallback)
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .youtubeMusic)
        XCTAssertEqual(report.state, .confirmedPlain)
    }

    func testOfficialFailureFallsBackAndNonYouTubeSongsSkipOfficial() async throws {
        let fallback = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let failing = YouTubeMusicFirstLyricsRepository(official: { _ in throw URLError(.timedOut) }, fallback: fallback)
        let report = try await failing.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)

        let neverCalled = YouTubeMusicFirstLyricsRepository(
            official: { _ in XCTFail("official lookup needs a YouTube video ID"); return nil }, fallback: fallback)
        _ = try await neverCalled.lookup(context: LyricsLookupContext(title: "Song", artist: "Artist"))
    }
}

private final class RecordingLyricsRepository: LyricsRepositoryProtocol, @unchecked Sendable {
    private let lyrics: SyncedLyrics?
    private(set) var calls = 0

    init(lyrics: SyncedLyrics?) { self.lyrics = lyrics }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        calls += 1
        return .legacy(lyrics)
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { lyrics }
}
