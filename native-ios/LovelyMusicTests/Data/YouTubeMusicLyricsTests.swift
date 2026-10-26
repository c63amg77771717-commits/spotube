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
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.timed }, fallbacks: [fallback])
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .youtubeMusic)
        XCTAssertEqual(report.state, .synchronized)
        XCTAssertEqual(fallback.calls, 0)
    }

    func testFallbackTimelineBeatsOfficialPlainText() async throws {
        let fallback = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.plain }, fallbacks: [fallback])
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)
        XCTAssertEqual(fallback.calls, 1)
    }

    func testOfficialPlainTextBeatsNoFallbackMatch() async throws {
        let fallback = RecordingLyricsRepository(lyrics: nil)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in Self.plain }, fallbacks: [fallback])
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .youtubeMusic)
        XCTAssertEqual(report.state, .confirmedPlain)
    }

    func testOfficialFailureFallsBackAndNonYouTubeSongsSkipOfficial() async throws {
        let fallback = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let failing = YouTubeMusicFirstLyricsRepository(official: { _ in throw URLError(.timedOut) }, fallbacks: [fallback])
        let report = try await failing.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)

        let neverCalled = YouTubeMusicFirstLyricsRepository(
            official: { _ in XCTFail("official lookup needs a YouTube video ID"); return nil }, fallbacks: [fallback])
        _ = try await neverCalled.lookup(context: LyricsLookupContext(title: "Song", artist: "Artist"))
    }

    func testLaterFallbackTimelineIsUsedWhenEarlierOnlyHasPlainText() async throws {
        let netease = RecordingLyricsRepository(lyrics: Self.plain)
        let lrclib = RecordingLyricsRepository(lyrics: Self.lrclibTimed)
        let repository = YouTubeMusicFirstLyricsRepository(official: { _ in nil }, fallbacks: [netease, lrclib])
        let report = try await repository.lookup(context: context())
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)
        XCTAssertEqual(report.state, .synchronized)

        let noTimeline = YouTubeMusicFirstLyricsRepository(
            official: { _ in nil }, fallbacks: [RecordingLyricsRepository(lyrics: nil), netease])
        let firstWithContent = try await noTimeline.lookup(context: context())
        XCTAssertEqual(firstWithContent.state, .confirmedPlain)
    }

    func testRemoteClientVersionIsValidatedAndCached() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "YouTubeMusicLyricsTests.\(UUID().uuidString)"))
        XCTAssertEqual(YouTubeMusicLyricsClientConfig.androidMusicVersion(defaults: defaults), "7.27.52")
        XCTAssertFalse(YouTubeMusicLyricsClientConfig.apply(Data(#"{"androidMusicVersion":"latest; drop"}"#.utf8), defaults: defaults))
        XCTAssertFalse(YouTubeMusicLyricsClientConfig.apply(Data("not json".utf8), defaults: defaults))
        XCTAssertEqual(YouTubeMusicLyricsClientConfig.androidMusicVersion(defaults: defaults), "7.27.52")
        XCTAssertTrue(YouTubeMusicLyricsClientConfig.apply(Data(#"{"androidMusicVersion":" 8.01.3 "}"#.utf8), defaults: defaults))
        XCTAssertEqual(YouTubeMusicLyricsClientConfig.androidMusicVersion(defaults: defaults), "8.01.3")
    }

    func testNetEaseSearchAndLyricParsing() throws {
        let search = Data("""
        {"result":{"songs":[
          {"id":29713754,"name":"匆匆那年","artists":[{"name":"王菲"}],"album":{"name":"匆匆那年"},"duration":241000},
          {"id":1297986663,"name":"FRIENDS","artists":[{"name":"Marshmello"},{"name":"Anne-Marie"}],"duration":203000},
          {"id":1,"name":"no artist","artists":[]}
        ]},"code":200}
        """.utf8)
        let songs = try NetEaseLyricsService.songs(from: search)
        XCTAssertEqual(songs.map(\.id), [29713754, 1297986663])
        XCTAssertEqual(songs[1].artist, "Marshmello/Anne-Marie")
        XCTAssertEqual(songs[0].duration, 241)

        let lyric = Data(#"{"lrc":{"lyric":"[00:14.17]我已经\n"},"code":200}"#.utf8)
        XCTAssertEqual(try NetEaseLyricsService.lrc(from: lyric), "[00:14.17]我已经\n")
        XCTAssertNil(try NetEaseLyricsService.lrc(from: Data(#"{"nolyric":true,"code":200}"#.utf8)))
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
