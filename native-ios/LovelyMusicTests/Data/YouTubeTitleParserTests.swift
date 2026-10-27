import XCTest
@testable import LovelyMusic

/// Real titles from the user's playlist (2026-10-26 sample).
final class YouTubeTitleParserTests: XCTestCase {
    private typealias Guess = YouTubeTitleParser.Guess

    func testFirstGuessForPlaylistTitles() {
        let cases: [(String, Guess)] = [
            ("丁噹 - 可以不可以", .init(artist: "丁噹", song: "可以不可以")),
            ("TANK [ 你的情歌 Your Love Song ] Official Music Video (電影【你的情歌】主題曲)", .init(artist: "TANK", song: "你的情歌 Your Love Song")),
            ("風小箏 - 別丟下我不管「高音質 x 動態歌詞 Lyrics」♪ SDPMusic ♪", .init(artist: "風小箏", song: "別丟下我不管")),
            ("王菲 - 如願 MV（《我和我的父輩》主題推廣曲）（2021）", .init(artist: "王菲", song: "如願")),
            ("徐佳瑩 LaLa【到此為止 From Now On】Official Music Video", .init(artist: "徐佳瑩", song: "到此為止 From Now On")),
            ("戴羽彤 - 騙子 (原唱:文夫)『我不過一笑了之，你那蓄謀已久的轉身離開。』【高音質|動態歌詞Lyrics】♫", .init(artist: "戴羽彤", song: "騙子")),
            ("郁可唯/胡夏 《知否知否》|電視劇《知否知否應是綠肥紅瘦》主題曲高音質歌詞版MV（趙麗穎，馮紹峰，朱一龍主演）|The", .init(artist: "郁可唯/胡夏", song: "知否知否")),
            ("[官方版MV]張靚穎《十里桃花》(電影《三生三世十里桃花》主題曲)", .init(artist: "張靚穎", song: "十里桃花")),
            ("張韶涵 Angela Zhang - 口袋的天空 (官方版MV)", .init(artist: "張韶涵", song: "口袋的天空")),
            ("Ed Sheeran - Perfect (Official Music Video)", .init(artist: "Ed Sheeran", song: "Perfect")),
            ("希望你被这个世界爱着", .init(artist: "", song: "希望你被这个世界爱着")),
            ("大笛-盧一笛 - 對不起我放棄『當初是你一點一點慢慢向我靠近，現在換我一步一步退回安全距離。』【高音質|動態歌詞Lyrics】", .init(artist: "大笛-盧一笛", song: "對不起我放棄")),
            ("許茹芸〈健忘〉MV（【被偷走的那五年】電影插曲)", .init(artist: "許茹芸", song: "健忘")),
            ("【互動占星MV】戴佩妮《純屬意外》Official 完整版 MV [HD]", .init(artist: "戴佩妮", song: "純屬意外")),
            ("張韶涵 - 暮色回響『神啊可不可以讓我感受一下，看在我們對彼此都放心不下。』【高音質|動態歌詞Lyrics】♫ ·《默殺》", .init(artist: "張韶涵", song: "暮色回響")),
            ("徐佳瑩  一愛難求 -- 電視劇《扶搖》片尾曲", .init(artist: "徐佳瑩", song: "一愛難求")),
            ("程響 - 千里共嬋娟 | 可否一續前緣 | [動態歌詞 Lyric Video]", .init(artist: "程響", song: "千里共嬋娟")),
            ("蕭煌奇-心裡有針，Xiao Huangchi- \"Needle in My Heart\"", .init(artist: "蕭煌奇", song: "心裡有針")),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(YouTubeTitleParser.guesses(title).first, expected, title)
        }
    }

    func testAlternativeGuessesCoverReversedAndSpaceSeparatedCredits() {
        let cases: [(String, Guess)] = [
            ("鄧紫棋 泡沫 歌詞", .init(artist: "鄧紫棋", song: "泡沫")),
            ("如果你是我的传说 刘德华 (歌词版)", .init(artist: "刘德华", song: "如果你是我的传说")),
            ("我變成了我 [ Become Me ] - 陳思函（Angel ）", .init(artist: "陳思函", song: "我變成了我")),
        ]
        for (title, expected) in cases {
            XCTAssertTrue(YouTubeTitleParser.guesses(title).contains(expected), "\(title): \(YouTubeTitleParser.guesses(title))")
        }
    }

    /// Shapes found in the 3×60-song sample (2026-10-27).
    func testMoreCreditShapes() {
        let cases: [(String, Guess)] = [
            ("A Lin 幸福了 然後呢", .init(artist: "A Lin", song: "幸福了 然後呢")),
            ("羽泉 / 這一生都只為你【歌詞】", .init(artist: "羽泉", song: "這一生都只為你")),
            ("Paramore - Stay The Night ft. Hayley Williams", .init(artist: "Paramore", song: "Stay The Night")),
            ("Kelly Clarkson l Because of You", .init(artist: "Kelly Clarkson", song: "Because of You")),
            ("柯有倫 - 情歌變的不好聽 動態歌詞版", .init(artist: "柯有倫", song: "情歌變的不好聽")),
            ("《是你》张靓颖/王赫野", .init(artist: "张靓颖/王赫野", song: "是你")),
            ("\u{200B}王菲 - 紅豆", .init(artist: "王菲", song: "紅豆")),
            ("蔡健雅-紅色高跟鞋『你像窝在被子里的舒服』【動態歌詞Lyrics】", .init(artist: "蔡健雅", song: "紅色高跟鞋")),
            ("李佳薇-大火(Jess Lee - Burn) 完整版MV -華納official HQ官方版MV", .init(artist: "李佳薇", song: "大火")),
        ]
        XCTAssertTrue(YouTubeTitleParser.guesses("遇見 ~ 孫燕姿 ( 動態歌詞 )").contains(.init(artist: "孫燕姿", song: "遇見")))
        XCTAssertTrue(YouTubeTitleParser.artistsMatch("Soo Wincci", "Wincci 蘇盈之"))
        for (title, expected) in cases {
            XCTAssertEqual(YouTubeTitleParser.guesses(title).first, expected, title)
        }
    }

    func testFuzzyTitleAndArtistMatching() {
        let key = YouTubeTitleParser.normalized
        XCTAssertTrue(YouTubeTitleParser.titlesMatch(key("情歌變的不好聽"), key("情歌變得不好聽")))
        XCTAssertFalse(YouTubeTitleParser.titlesMatch(key("泡沫"), key("泡泡")))
        XCTAssertTrue(YouTubeTitleParser.artistsMatch("柯有綸", "柯有倫"))
        XCTAssertTrue(YouTubeTitleParser.artistsMatch("G.E.M. 鄧紫棋", "邓紫棋"))
        XCTAssertTrue(YouTubeTitleParser.artistsMatch("李毓芬 Tia Lee", "Tia Lee"))
        XCTAssertFalse(YouTubeTitleParser.artistsMatch("王菲", "王菲菲"))
    }

    func testFirstTakeIsAnotherVersion() {
        XCTAssertNil(YouTubeTitleParser.bestMatch([record("如愿 (THE FIRST TAKE)", "王菲", 265)],
                                                  guess: .init(artist: "王菲", song: "如願"), videoTitle: "王菲 - 如願 MV",
                                                  videoDuration: 267, titleHasArtist: true))
    }

    func testMuchLongerRecordIsAnotherVersion() {
        let guess = Guess(artist: "张靓颖", song: "画心")
        XCTAssertNil(YouTubeTitleParser.bestMatch([record("画心", "张靓颖", 433)], guess: guess,
                                                  videoTitle: "画心 张靓颖KTV版", videoDuration: 268, titleHasArtist: true))
        XCTAssertNotNil(YouTubeTitleParser.bestMatch([record("画心", "张靓颖", 250)], guess: guess,
                                                     videoTitle: "画心 张靓颖KTV版", videoDuration: 268, titleHasArtist: true))
    }

    func testSongVariantsDropEnglishTranslation() {
        XCTAssertEqual(YouTubeTitleParser.songVariants("到此為止 From Now On"), ["到此為止 From Now On", "到此為止"])
        XCTAssertEqual(YouTubeTitleParser.songVariants("Perfect"), ["Perfect"])
    }

    private func record(_ title: String, _ artist: String, _ duration: Double) -> YouTubeTitleParser.Record {
        .init(title: title, artist: artist, duration: duration)
    }

    func testMatchingAcrossTraditionalAndSimplifiedPrefersClosestLength() {
        let match = YouTubeTitleParser.bestMatch(
            [record("可以不可以", "丁当", 300), record("可以不可以", "丁当", 281.866), record("可以不可以", "王菲菲", 282)],
            guess: .init(artist: "丁噹", song: "可以不可以"), videoTitle: "丁噹 - 可以不可以",
            videoDuration: 282, titleHasArtist: true)
        XCTAssertEqual(match?.duration, 281.866)
    }

    func testMatchingRejectsOtherArtistsVersionsAndPartialTitles() {
        let guess = Guess(artist: "王菲", song: "如願")
        let wrong = [record("如愿", "王菲菲", 265), record("如愿 (Live)", "王菲", 265),
                     record("如愿（伴奏）", "王菲", 265), record("组曲：如愿+红豆", "王菲", 265)]
        XCTAssertNil(YouTubeTitleParser.bestMatch(wrong, guess: guess, videoTitle: "王菲 - 如願 MV",
                                                  videoDuration: 267, titleHasArtist: true))
        // A live video may match a live record.
        XCTAssertNotNil(YouTubeTitleParser.bestMatch([record("如愿 (Live)", "王菲", 265)], guess: guess,
                                                     videoTitle: "王菲 - 如願 (Live)", videoDuration: 267, titleHasArtist: true))
    }

    func testTitleWithoutArtistNeedsSameLengthRecording() {
        let guess = Guess(artist: "", song: "錯了")
        XCTAssertNotNil(YouTubeTitleParser.bestMatch([record("错了", "苏见信 (信)", 261.306)], guess: guess,
                                                     videoTitle: "錯了", videoDuration: 261, titleHasArtist: false))
        XCTAssertNil(YouTubeTitleParser.bestMatch([record("错了", "某人", 200)], guess: guess,
                                                  videoTitle: "錯了", videoDuration: 261, titleHasArtist: false))
        // When the title names an artist, an artist-less guess never matches.
        XCTAssertNil(YouTubeTitleParser.bestMatch([record("错了", "苏见信 (信)", 261.306)], guess: guess,
                                                  videoTitle: "信 - 錯了", videoDuration: 261, titleHasArtist: true))
    }

    func testCreditLinesAreRemovedFromLRC() {
        let lrc = "[00:00.00] 作词 : 王菲\n[00:02.03] 制作人 : 梁翘柏\n[00:14.17]我已经\n"
        XCTAssertEqual(TitleMatchedLyricsService.withoutCredits(lrc), "[00:14.17]我已经\n")
    }

    func testServiceUsesNetEaseTimelineThatMatchesTheVideo() async throws {
        let search = #"{"result":{"songs":[{"id":7,"name":"可以不可以","artists":[{"name":"丁当"}],"duration":281866}]}}"#
        let lyric = #"{"lrc":{"lyric":"[00:00.00] 作词 : 某人\n[00:10.00]第一句\n[00:20.00]第二句\n"}}"#
        let service = TitleMatchedLyricsService(fetch: { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("music.163.com/api/search") { return Data(search.utf8) }
            if url.contains("music.163.com/api/song/lyric") { return Data(lyric.utf8) }
            throw URLError(.badServerResponse)
        })
        let context = LyricsLookupContext(songID: "fYZhA9-bFv8", title: "丁噹 - 可以不可以", artist: "",
                                          duration: 282, hasYouTubeOrigin: true)
        let report = try await service.lookup(context: context)
        XCTAssertEqual(report.state, .synchronized)
        XCTAssertEqual(report.lyrics?.providerID, .netease)
        XCTAssertEqual(report.lyrics?.lines.map(\.text), ["第一句", "第二句"])
        XCTAssertEqual(report.lyrics?.lines.map(\.time), [10, 20])
    }

    func testServiceFallsBackToLrcLibWhenNetEaseFails() async throws {
        let lrclib = #"[{"trackName":"Perfect","artistName":"Ed Sheeran","duration":280.0,"instrumental":false,"plainLyrics":"I found a love","syncedLyrics":"[00:05.00]I found a love"}]"#
        let service = TitleMatchedLyricsService(fetch: { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("lrclib.net/api/search") { return Data(lrclib.utf8) }
            throw URLError(.cannotConnectToHost)
        })
        let context = LyricsLookupContext(songID: "2Vv-BfVoq4g", title: "Ed Sheeran - Perfect (Official Music Video)",
                                          artist: "", duration: 280, hasYouTubeOrigin: true)
        let report = try await service.lookup(context: context)
        XCTAssertEqual(report.lyrics?.providerID, .lrclib)
        XCTAssertEqual(report.state, .synchronized)
    }
}
