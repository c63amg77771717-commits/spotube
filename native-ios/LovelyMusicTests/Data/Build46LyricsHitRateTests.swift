import XCTest
@testable import LovelyMusic

/// Live lookup of popular Chinese, Japanese, and English songs through the
/// production chain (YouTube Music, then NetEase, then LRCLIB).
/// Runs when EVANTUBE_LIVE_LYRICS=1, same as the playlist evaluation.
final class Build46LyricsHitRateTests: XCTestCase {
    static let songs: [(title: String, artist: String, duration: Int)] = [
        ("周杰倫 Jay Chou【晴天 Sunny Day】Official MV", "周杰倫", 269),
        ("G.E.M. 鄧紫棋【光年之外】Official MV", "鄧紫棋", 235),
        ("五月天 Mayday【倔強】Official Music Video", "五月天", 254),
        ("告五人 - 愛人錯過【動態歌詞】", "告五人", 292),
        ("周深 - 大魚", "周深", 311),
        ("YOASOBI「アイドル」Official Music Video", "YOASOBI", 213),
        ("米津玄師 Kenshi Yonezu - Lemon", "米津玄師", 267),
        ("優里 - ドライフラワー Official Music Video", "優里", 226),
        ("Official髭男dism - Pretender", "Official髭男dism", 327),
        ("Ed Sheeran - Shape of You (Official Music Video)", "Ed Sheeran", 263),
        ("Adele - Hello", "Adele", 295),
        ("Taylor Swift - Anti-Hero (Official Music Video)", "Taylor Swift", 201),
    ]

    func testPopularSongsFindLyrics() async throws {
        guard ProcessInfo.processInfo.environment["EVANTUBE_LIVE_LYRICS"] == "1" else {
            throw XCTSkip("live Chinese/Japanese/English lyric check runs in the Build46 lyric job")
        }
        let suite = "Build46LyricsHitRate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = YouTubeMusicLyricsService()
        let catalog = OfficialAudioCatalog(search: { try await service.searchSongs($0) }, defaults: defaults,
                                           timeout: .seconds(8))
        let repository = YouTubeMusicFirstLyricsRepository(
            fallbacks: [TitleMatchedLyricsService(), LrcLibService()], officialAudio: catalog)
        var text = 0
        var synced = 0
        for song in Self.songs {
            let context = LyricsLookupContext(songID: "live-\(song.title.hashValue)", title: song.title,
                                              artist: song.artist, duration: song.duration, hasYouTubeOrigin: true)
            let report = try await repository.lookup(context: context)
            let lyrics = report.lyrics
            let found = lyrics.map { !$0.lines.isEmpty } ?? false
            if found { text += 1 }
            if report.state == .synchronized { synced += 1 }
            print("HIT-RATE \(found ? "text" : "miss") \(report.state.rawValue) \(lyrics?.providerID?.rawValue ?? "-") "
                  + "lines=\(lyrics?.lines.count ?? 0) | \(song.artist) - \(song.title)")
        }
        print("HIT-RATE SUMMARY text=\(text)/\(Self.songs.count) synced=\(synced)/\(Self.songs.count)")
        XCTAssertGreaterThanOrEqual(text, 8, "lyrics found for fewer than 8 of 12 popular songs")
        XCTAssertGreaterThanOrEqual(synced, 4, "timed lyrics found for fewer than 4 of 12 popular songs")
    }
}
