import Foundation
import XCTest
@testable import LovelyMusic

/// Live network evaluation of the production lyric chain on 60 random songs of
/// the user's playlist (seed 60601), in audio mode: a song with an official
/// YouTube Music audio version plays that version, and lyrics follow it.
/// Runs only with EVANTUBE_LIVE_LYRICS=1. The offline Python replica of this
/// flow aligned 50 of 60 timelines (2026-10-27); the rest are covers, remixes,
/// KTV or variety-show takes, or songs YouTube Music does not carry.
final class LiveLyricsEvaluationTests: XCTestCase {
    static let songs: [(id: String, title: String, duration: Int)] = [
        ("UNgHD07NQKU", "G.E.M. 鄧紫棋【只有我和你的地方 ME & YOU】Official Music Video | Chapter 03 | 啓示錄 REVELATION", 216),
        ("vZOqNtcHLMg", "毛不易 - 無名的人『無名的人啊，我敬你一杯酒』【Lyrics Video】", 282),
        ("OrFM4ES3IbE", "座位", 246),
        ("B1WqF-XPZ6U", "戴愛玲Princess Ai 《沸騰》Official Music Video", 307),
        ("jeRu6h4XbUU", "A-Lin《幸福在歌唱 Happiness Is Singing》Official Music Video - 電影《陽光女子合唱團》幸福版主題曲", 280),
        ("WOQwWU9BVi0", "画心 张靓颖KTV版（电影《画皮》主题曲） 超清", 268),
        ("6PqSFtPxVY8", "F.I.R. 飛兒樂團 - 亞特蘭提斯 (Official官方完整海外版MV)", 234),
        ("UuTBI3MY_ic", "【延禧攻略】片尾曲 《雪落下的聲音》李千那 Cover", 265),
        ("8EA71rLoY5s", "牛奶咖啡 - 明天你好『长大以后 我只能奔跑』【動態歌詞Lyrics】", 272),
        ("67Bn4EU_QG4", "梦一场 (Live)", 210),
        ("dI87n5rkseY", "月烬无声", 234),
        ("HdHHp_tDxQw", "張靚穎《無念》(霍建華,楊冪電視劇《築夢情緣》女主情感主題曲)", 275),
        ("HWrDNKJ8TwU", "李夢尹 - 雨下的瞬間『再看你一眼，還能否回到你身邊？』【動態歌詞Lyrics】", 273),
        ("Qw4oUF4o8t0", "戴佩妮-淡水河邊", 316),
        ("rgTQYCo0WCM", "蕭秉治Xiao Bing Chih [ 毒藥 Addiction ] Official Music Video", 301),
        ("WWX4OD-fge0", "戴佩妮  Penny Tai - 怎樣 What If We Still Stay Together? (官方完整版MV)", 272),
        ("fGJbBIgVsks", "張語噥 Sammy  -【別想太多】Official MV", 234),
        ("zayt3s5MrZo", "黃禮格 - 黃禮格《失眠》Official Music Video", 245),
        ("77Ojf1bU2Ck", "Torn Apart (Hard3Eat Remix)", 187),
        ("nlg1y6hLsRs", "一直很安静 - 阿桑", 250),
        ("6VMZsMjfiEQ", "蕭煌奇 Ricky Xiao - 死心了沒有 Not Over You (華納 official HD MV)", 323),
        ("jyDmarNX3xs", "渡我", 277),
        ("P67SgjzO4jk", "Happier - (Echofy Max Music Video)", 260),
        ("2gEw-Ta8c24", "張碧晨【年輪】官方歌詞版 MV（花千骨電視劇插曲）", 275),
        ("H6SShCF58-U", "方泂鑌 A-Bin【最笨的人是我 The Fool】特別演出：嚴正嵐、張耀仁 HD 高清官方完整版 MV", 331),
        ("ZV64-2GmInA", "羽泉 / 這一生都只為你【歌詞】", 277),
        ("e04wIcfMDqo", "薩吉 - 玄鳥【《長月燼明 Till The End of The Moon》電視劇插曲 - 動態歌詞】=只為遇見你，一生遙望。《玄鳥》降落，停在你掌心就好。= TV series OST", 256),
        ("-1G-ZUbyBCU", "不安 - 莊心妍 Ada『是我太過愛你 才有不安的心理 太想去擁抱你 才會掉進了恐懼』【動態歌詞】", 258),
        ("o0TyNAdsKZ8", "【纯享版】张含韵姚晓棠催泪献唱《妥协》俩人温柔又充满力量的声线 教人在爱情漩涡中找寻自我  #天赐的声音5 EP8 20240614", 242),
        ("1sioip9Uc4o", "Can You Feel The Love Tonight (The Lion King) - Elton John (Boyce Avenue ft. Connie Talbot cover)", 261),
        ("vKxkRn0nsr0", "蕭賀碩 不公平 MV", 247),
        ("qe_YIfZ1OJs", "寄长月 - 不才 ( 电视剧长月烬明 ) Till The End Of The Moon MV", 286),
        ("4KPVpDuk5Gw", "好可惜", 309),
        ("_uVCIaTUYJw", "戴羽彤 - 可以不是你『後來他讓我明白 原來我也值得被珍惜，那最後的人真的可以不是你。』【高音質|動態歌詞Lyrics】♫", 216),
        ("F6azCeyE3L8", "彭佳慧 - 相見恨晚", 255),
        ("vcXeF3sNNJY", "盛夏的告别 (电视剧《我的人间烟火》思念主题曲)", 292),
        ("zxiIp8Wexps", "李毓芬 Tia Lee《早應該We Should Have》Official Music Video HD", 271),
        ("X4Pm08gIqbc", "梁靜茹 Fish Leong【別人的天長地久 Someone Else's Eternal Love】Official Music Video", 289),
        ("nmJUVhjwZ4Y", "程響 - 四季予你『大雪漫天飄零 做你的嫁衣多美麗』【動態歌詞】", 249),
        ("OnqkY3wZcyo", "邱軍 Kui  l 我不會【高音質 動態歌詞 Lyrics】", 216),
        ("_BshMLSUsW8", "ycccc - 滿天星辰不及你『星際閃耀光影 落入你的眼睛，我們共赴一場 光年的旅行。』【高音質|動態歌詞Lyrics】♫", 216),
        ("2JSDVQy6xAs", "告五人 - 愛人錯過『』【動態歌詞Lyrics】", 292),
        ("BpBTiOGuoWs", "徐佳瑩  一愛難求 -- 電視劇《扶搖》片尾曲", 266),
        ("frhm8DKOmWg", "范倪Liu - 空座位『明明座位為你留了 票也買好了，怎麼最後身邊還是空著。』【動態歌詞/Vietsub/Pinyin Lyrics】", 267),
        ("0D676uRWYPI", "蔡健雅 Tanya Chua - 十萬毫升淚水[Official Music Video]完整放映", 298),
        ("wBjHwY_NPDU", "ycccc - 潮汐（原唱：安蘇羽/傅夢彤）『藍色的海底 遠山的風景，我們的距離遙不可及。』【動態歌詞Lyrics】", 202),
        ("mLFhTFiX0uM", "周杰倫 Jay Chou【說好的幸福呢 The Promised Love】-Official Music Video", 257),
        ("K5rjNK_De-I", "張惠妹 - 人質(歌詞版)", 229),
        ("KKpIOkhKSUE", "李翊君-找不到人天荒地老", 238),
        ("Haha-Vc_9Cc", "白安ANN [ 最想見到你 Let’s be together ] Special Edition Music Video", 226),
        ("T253Ss8-Qro", "白安ANN [ 剛好Just Good Enough ] Official Music Video（戲劇《台北女子圖鑑》插曲）", 263),
        ("IdneKLhsWOQ", "Taylor Swift - Wildest Dreams", 235),
        ("uL58JC-5VfQ", "C=HD 張靚穎Jane Zhang【一定要幸福 Must Be Happy】高音質飯制版MV 新專輯《領銜主演》已上市   YouTube 360p", 295),
        ("tcQsNj2-gPY", "常艾非 - 不夠「為何逼著我說出分手。」動態歌詞版MV", 241),
        ("KUUjtUP2CrE", "Carrie Underwood - Cry Pretty (Official Music Video)", 269),
        ("QA8MdX8xpis", "張靚穎【幻紗之靈】Official Lyric Video -《王者榮耀》手遊西施英雄主打歌", 248),
        ("PWaEOmgzl8s", "大雨裏 - ycccc『那時多盼望雨停，多希望我不曾愛過你，多久後終能夠清醒』【動態歌詞】", 212),
        ("qCeBX8muMOc", "李佳薇 Jess Lee - 鍊愛 Chain of Love (華納 official HD 官方版MV)", 262),
        ("i2MdEuQGxNs", "不刪", 265),
        ("okLFMXHPgbg", "郑中基 - 《你的眼睛背叛你的心》 [歌词]", 269),
    ]

    func testPlaylistSampleFindsLyricsAndAlignedTimelines() async throws {
        guard ProcessInfo.processInfo.environment["EVANTUBE_LIVE_LYRICS"] == "1" else {
            throw XCTSkip("live network evaluation runs only in the lyric evaluation workflow")
        }
        let suite = "LiveLyricsEvaluationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = YouTubeMusicLyricsService()
        let catalog = OfficialAudioCatalog(search: { try await service.searchSongs($0) }, defaults: defaults,
                                           timeout: .seconds(10))
        let repository = YouTubeMusicFirstLyricsRepository(fallbacks: [TitleMatchedLyricsService()],
                                                           officialAudio: catalog)
        var synced = 0, text = 0, official = 0
        var lines: [String] = []
        for song in Self.songs {
            let context = LyricsLookupContext(songID: song.id, title: song.title, artist: "",
                                              duration: song.duration, hasYouTubeOrigin: true)
            let started = Date()
            let match = await catalog.lyricsMatch(for: context)
            let report = try await repository.lookup(context: context)
            let seconds = Date().timeIntervalSince(started)
            let lyrics = report.lyrics
            if match != nil { official += 1 }
            if report.state == .synchronized { synced += 1 }
            if let lyrics, !lyrics.lines.isEmpty { text += 1 }
            let provider = lyrics?.providerID?.rawValue ?? "-"
            let plays = match.map { "plays=\($0.videoID)(\($0.duration ?? 0)s)" } ?? "plays=video"
            let elapsed = (seconds * 10).rounded() / 10
            lines.append("LIVE-LYRICS \(song.id) \(report.state.rawValue) \(provider) \(plays) "
                + "lines=\(lyrics?.lines.count ?? 0) \(elapsed)s | \(song.title)")
        }
        lines.forEach { print($0) }
        print("LIVE-LYRICS SUMMARY synced=\(synced)/\(Self.songs.count) text=\(text)/\(Self.songs.count) "
            + "official-audio=\(official)/\(Self.songs.count)")
        XCTAssertGreaterThanOrEqual(synced, 40, "aligned timelines regressed below 2/3 (offline replica: 50)")
        XCTAssertGreaterThanOrEqual(text, 45, "lyric coverage regressed")
    }
}
