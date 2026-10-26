import Foundation
import XCTest
@testable import LovelyMusic

/// Live network evaluation of the production lyric chain on 30 random songs of
/// the user's playlist (seed 20261026). Runs only with EVANTUBE_LIVE_LYRICS=1.
/// The offline Python replica measured 11 aligned timelines and 27 with text
/// on this sample (2026-10-26); the test fails on a large regression.
final class LiveLyricsEvaluationTests: XCTestCase {
    static let songs: [(id: String, title: String, duration: Int)] = [
        ("PLh4L3vjJ8A", "希望你被这个世界爱着", 229),
        ("fYZhA9-bFv8", "丁噹 - 可以不可以", 282),
        ("MeGrr-lWpxU", "TANK [ 你的情歌 Your Love Song ] Official Music Video (電影【你的情歌】主題曲)", 288),
        ("YKQ-fyas_Vs", "風小箏 - 別丟下我不管「高音質 x 動態歌詞 Lyrics」♪ SDPMusic ♪", 277),
        ("0jeBnYQWs5s", "王菲 - 如願 MV（《我和我的父輩》主題推廣曲）（2021）", 267),
        ("yC26AtfLQpU", "亦帆Canace 另存心檔【踏破鐵鞋】(八大綜合台''笑傲江湖''片尾曲) 官方Official MV (HD)", 307),
        ("WEWwtanev1g", "大笛-盧一笛 - 對不起我放棄『當初是你一點一點慢慢向我靠近，現在換我一步一步退回安全距離。』【高音質|動態歌詞Lyrics】♫", 255),
        ("T7IK_5XCRiU", "徐佳瑩 LaLa【到此為止 From Now On】Official Music Video", 295),
        ("g6741ak1ysQ", "周筆暢 Bibi Chou《藏心 Hidden Heart》【錦繡南歌 The Song of Glory OST電視劇片尾主題曲】官方動態歌詞MV (無損高音質)", 243),
        ("IDJccHlRasc", "週間", 286),
        ("dpjz5uRCXTg", "Evanescence - Imaginary (Remastered 2023) - Official Visualizer", 257),
        ("LyGeoF1K10o", "謝安琪Kay Tse - 我們都被忘了 (官方完整版MV)", 280),
        ("vGqpGFH3vh8", "A-Lin《摯友 Best Friend》Official Music Video", 333),
        ("IDhZy6tfJGY", "張韶涵 Angela Zhang - 口袋的天空 (官方版MV)", 264),
        ("UoPRTkK5KG4", "戴羽彤 - 騙子 (原唱:文夫)『我不過一笑了之，你那蓄謀已久的轉身離開。』【高音質|動態歌詞Lyrics】♫", 212),
        ("KwBVgLcyejg", "程響 - 萬物可期『可惜 你不經意留下的輪廓，我卻需要用一生去描摹。』【高音質|動態歌詞Lyrics】♫", 225),
        ("BpBTiOGuoWs", "徐佳瑩  一愛難求 -- 電視劇《扶搖》片尾曲", 266),
        ("XDqnUPuW448", "錯了", 261),
        ("x3bDhtuC5yk", "茄子蛋EggPlantEgg - 浪子回頭 Back Here Again (Official Music Video)", 291),
        ("4y8mcGll_Ag", "[中+Eng Sub MV] Forget You 忘憂(漫夭主題曲-張雪迎 飾)白髮王妃 Princess Silver OST", 244),
        ("2Vv-BfVoq4g", "Ed Sheeran - Perfect (Official Music Video)", 282),
        ("hwENuZHFTj0", "G.E.M. 鄧紫棋【冰河時代 ICE AGE】Official Music Video | Chapter 07 | 啓示錄 REVELATION", 222),
        ("gqpGr_QlUR0", "蕭煌奇-心裡有針，Xiao Huangchi- \"Needle in My Heart\"", 313),
        ("zbGSdKDIPtQ", "卓文萱 Genie Chuo【被你愛過我很快樂】Official Music Video", 271),
        ("_Ay8m24gf64", "错错错（原版MV）All your wrong - 六哲、陈娟儿.f4v", 284),
        ("kSXt-xelEBc", "[官方版MV]張靚穎《十里桃花》(電影《三生三世十里桃花》主題曲)", 197),
        ("xoH29SM3e8I", "郁可唯/胡夏 《知否知否》|電視劇《知否知否應是綠肥紅瘦》主題曲高音質歌詞版MV（趙麗穎，馮紹峰，朱一龍主演）|The Story Of MingLan OST", 276),
        ("NVCatRLxl5Y", "Priscilla Abby 蔡恩雨《祝你幸福》官方Official MV", 350),
        ("0qTIO1VGsJ0", "戴愛玲Princess Ai 《累格》Official Music Video", 331),
        ("tln-FPsf4tg", "張韶涵 - 暮色回響『神啊可不可以讓我感受一下，看在我們對彼此都放心不下。』【高音質|動態歌詞Lyrics】♫ ·《默殺》電影推廣曲 (原唱:吉星出租)", 185),
    ]

    func testPlaylistSampleFindsLyricsAndAlignedTimelines() async throws {
        guard ProcessInfo.processInfo.environment["EVANTUBE_LIVE_LYRICS"] == "1" else {
            throw XCTSkip("live network evaluation runs only in the lyric evaluation workflow")
        }
        let repository = YouTubeMusicFirstLyricsRepository(fallbacks: [TitleMatchedLyricsService()])
        var synced = 0, text = 0
        var lines: [String] = []
        for song in Self.songs {
            let context = LyricsLookupContext(songID: song.id, title: song.title, artist: "",
                                              duration: song.duration, hasYouTubeOrigin: true)
            let started = Date()
            let report = try await repository.lookup(context: context)
            let seconds = Date().timeIntervalSince(started)
            let lyrics = report.lyrics
            if report.state == .synchronized { synced += 1 }
            if let lyrics, !lyrics.lines.isEmpty { text += 1 }
            let provider = lyrics?.providerID?.rawValue ?? "-"
            let elapsed = (seconds * 10).rounded() / 10
            lines.append("LIVE-LYRICS \(song.id) \(report.state.rawValue) \(provider) "
                + "lines=\(lyrics?.lines.count ?? 0) \(elapsed)s | \(song.title)")
        }
        lines.forEach { print($0) }
        print("LIVE-LYRICS SUMMARY synced=\(synced)/\(Self.songs.count) text=\(text)/\(Self.songs.count)")
        XCTAssertGreaterThanOrEqual(synced, 7, "aligned timelines regressed far below the offline replica (11)")
        XCTAssertGreaterThanOrEqual(text, 20, "lyric coverage regressed far below the offline replica (27)")
    }
}
