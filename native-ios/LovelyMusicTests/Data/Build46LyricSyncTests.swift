import XCTest
@testable import LovelyMusic

/// Lyric clock, LRC timestamps, CJK/Japanese lookup text, and the Opus/AAC plan.
final class Build46LyricSyncTests: XCTestCase {
    func testMillisecondAndRepeatedTimestampsAndOffset() {
        let parsed = LyricsMatchingPolicy.parseLRCResult("""
        [offset:+1500]
        [00:01.00][00:02.500]Same line
        [01:02.003]Three digits
        [01:02:03]Colon centiseconds
        """)
        XCTAssertFalse(parsed.unsupportedOffset)
        XCTAssertEqual(parsed.invalidTimestampCount, 0)
        XCTAssertEqual(parsed.lines.count, 4)
        XCTAssertEqual(parsed.lines[0].time, 2.5, accuracy: 0.000_1)          // 1.00 + 1.50
        XCTAssertEqual(parsed.lines[1].time, 4.0, accuracy: 0.000_1)          // 2.500 + 1.50
        XCTAssertEqual(parsed.lines[0].text, parsed.lines[1].text)
        XCTAssertEqual(parsed.lines[2].time, 63.503, accuracy: 0.000_1)       // 62.003 + 1.50
        XCTAssertEqual(parsed.lines[3].time, 63.53, accuracy: 0.000_1)        // 62.03 + 1.50
        let earlier = LyricsMatchingPolicy.parseLRCResult("[offset:-500]\n[00:02.00]Back")
        XCTAssertEqual(earlier.lines.first?.time ?? -1, 1.5, accuracy: 0.000_1)
    }

    func testLyricClockMatchesAcrossOpusAndAACAndIgnoresWallClockAndDurationStretch() {
        let times = [0.0, 1.5, 12.003, 30.0]
        let aacOffset = 2112.0 / 44100.0
        let opusOffset = 312.0 / 48000.0
        let videoPosition = 12.05
        let aac = LyricPlaybackClock.Anchor(timelineOffset: aacOffset, timelineDuration: 200,
                                            playingDuration: 200, authoredForPlayingSource: true)
        let opus = LyricPlaybackClock.Anchor(timelineOffset: opusOffset, timelineDuration: 200,
                                             playingDuration: 205, authoredForPlayingSource: true)
        let aacLyric = LyricPlaybackClock.lyricTime(playerTime: videoPosition - aacOffset, anchor: aac)
        let opusLyric = LyricPlaybackClock.lyricTime(playerTime: videoPosition - opusOffset, anchor: opus)
        XCTAssertEqual(aacLyric, opusLyric, accuracy: 0.000_1)
        XCTAssertEqual(aacLyric, videoPosition, accuracy: 0.000_1)
        XCTAssertEqual(LyricPlaybackClock.activeLineIndex(times: times, lyricTime: aacLyric),
                       LyricPlaybackClock.activeLineIndex(times: times, lyricTime: opusLyric))
        XCTAssertEqual(LyricPlaybackClock.activeLineIndex(times: times, lyricTime: aacLyric), 2)

        // Seek jumps the cue. Waiting does not: the same player time is the same cue.
        XCTAssertEqual(LyricPlaybackClock.activeLineIndex(times: times, lyricTime: 0.2), 0)
        XCTAssertEqual(LyricPlaybackClock.activeLineIndex(times: times, lyricTime: 31), 3)
        let held = LyricPlaybackClock.lyricTime(playerTime: 10, anchor: aac)
        XCTAssertEqual(LyricPlaybackClock.lyricTime(playerTime: 10, anchor: aac), held)

        // A longer music video must not stretch the cues.
        let stretched = LyricPlaybackClock.lyricTime(
            playerTime: 10, anchor: .init(timelineDuration: 180, playingDuration: 240))
        XCTAssertEqual(stretched, 10, accuracy: 0.000_1)
    }

    func testChineseAndJapaneseQueriesKeepBothScripts() {
        XCTAssertEqual(YouTubeTitleParser.searchForms("アイドル YOASOBI"), ["アイドル YOASOBI"])
        XCTAssertTrue(YouTubeTitleParser.guesses("YOASOBI「アイドル」Official Music Video")
            .contains { $0.artist == "YOASOBI" && $0.song == "アイドル" })
        XCTAssertTrue(YouTubeTitleParser.guesses("【MV】優里 - ドライフラワー")
            .contains { $0.artist == "優里" && $0.song == "ドライフラワー" })
        XCTAssertTrue(YouTubeTitleParser.guesses("米津玄師 - Lemon（Official Video）")
            .contains { $0.song == "Lemon" && $0.artist.contains("米津") })
        let forms = YouTubeTitleParser.searchForms("鄧紫棋 光年之外")
        XCTAssertEqual(forms.first, YouTubeTitleParser.simplified("鄧紫棋 光年之外"))
        XCTAssertTrue(forms.contains("鄧紫棋 光年之外"))
        XCTAssertGreaterThan(forms.count, 1)
        let withArtist = YouTubeTitleParser.queries(title: "晴天", artist: "周杰倫", limit: 4)
        XCTAssertEqual(withArtist.first?.artist, "周杰倫")
        XCTAssertEqual(withArtist.first?.song, "晴天")
        let request = TitleMatchedLyricsService.neteaseSearch(.init(artist: "周杰倫", song: "晴天"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "s" }?.value
        XCTAssertEqual(query, YouTubeTitleParser.searchForms("晴天 周杰倫").first)
    }

    func testNearDurationStaysTimedWithoutRewritingTheRecording() async throws {
        let service = TitleMatchedLyricsService { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("search/get") {
                let json = #"{"result":{"songs":[{"id":7,"name":"晴天","artists":[{"name":"周杰倫"}],"duration":269000}]}}"#
                return Data(json.utf8)
            }
            let json = #"{"lrc":{"lyric":"[00:01.500]故事的小黃花\n[00:12.003]第二行"}}"#
            return Data(json.utf8)
        }
        let context = LyricsLookupContext(songID: "video", title: "周杰倫 - 晴天 Official MV", artist: "周杰倫",
                                          duration: 274, hasYouTubeOrigin: true)
        let report = try await service.lookup(context: context)
        let lyrics = try XCTUnwrap(report.lyrics)
        XCTAssertTrue(lyrics.isTimeSynced, "a 5 s gap used to be forced plain or relabeled as the video")
        XCTAssertEqual(lyrics.timelineDuration ?? -1, 269, accuracy: 0.01)
        XCTAssertEqual(lyrics.lines.first?.time ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines.last?.time ?? -1, 12.003, accuracy: 0.000_1)
    }

    func testOpusPlanDoesNotReplaceTheAACStartup() {
        func format(_ itag: Int, _ mime: String, _ bitrate: Int) -> StreamFormat {
            StreamFormat(itag: itag, url: "https://audio.example/\(itag)", mimeType: mime, bitrate: bitrate,
                         contentLength: "1000", quality: nil, audioQuality: nil, audioSampleRate: nil,
                         audioChannels: 2, approxDurationMs: "200000", width: nil, height: nil)
        }
        let formats = [
            format(140, "audio/mp4", 130_485),
            format(141, "audio/mp4", 256_000),
            format(251, "audio/webm; codecs=\"opus\"", 160_000),
            format(22, "video/mp4", 700_000),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let high = try XCTUnwrap(AudioSourcePlan.select(from: data, quality: .high))
        XCTAssertEqual(high.startup.itag, data.bestAudioFormat(quality: .high)?.itag)
        XCTAssertEqual(high.opusUpgrade?.itag, 251)
        XCTAssertEqual(high.aacFallback.itag, 141)
        let medium = try XCTUnwrap(AudioSourcePlan.select(from: data, quality: .medium))
        XCTAssertEqual(medium.startup.itag, 140, "medium still starts on the Build45 AAC")
        XCTAssertEqual(medium.aacFallback.itag, 140, "141 is above the medium cap, so fallback stays 140")
        XCTAssertEqual(medium.opusUpgrade?.itag, 251)
        let aacOnly = StreamingData(formats: [], adaptiveFormats: [formats[0], formats[1]], expiresAt: nil)
        XCTAssertNil(AudioSourcePlan.select(from: aacOnly, quality: .high)?.opusUpgrade)
        XCTAssertEqual(AudioSourcePlan.select(from: aacOnly, quality: .high)?.aacFallback.itag, 141)
    }

    func testWebMOpusPacketsBecomeACAFAndGarbageDoesNot() throws {
        let head = Data("OpusHead".utf8) + Data([1, 2, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0, 0, 0])
        let track = element([0xAE],
                            element([0xD7], [0x01])
                            + element([0x86], Array("A_OPUS".utf8))
                            + element([0x63, 0xA2], [UInt8](head)))
        let block = element([0xA3], [0x81, 0x00, 0x00, 0x80, 0x0B, 0x0C])
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], block)
        let segment = element([0x18, 0x53, 0x80, 0x67], element([0x16, 0x54, 0xAE, 0x6B], track) + cluster)
        let stream = try XCTUnwrap(WebMOpus.parse(Data(segment)))
        XCTAssertEqual(stream.channels, 2)
        XCTAssertEqual(stream.preSkip, 312)
        XCTAssertEqual(stream.packets, [Data([0x0B, 0x0C])])
        XCTAssertEqual(stream.preSkipSeconds, 312.0 / 48_000, accuracy: 0.000_001)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(WebMOpus.writeCAF(stream, to: url))
        let header = try Data(contentsOf: url).prefix(4)
        XCTAssertEqual(Array(header), Array("caff".utf8))
        XCTAssertNil(WebMOpus.parse(Data([0, 1, 2, 3])))
    }

    func testSIDXEarliestPresentationTimeIsSeconds() throws {
        var header = Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70])
        header.append(contentsOf: [
            0, 0, 0, 44, 0x73, 0x69, 0x64, 0x78,
            0, 0, 0, 0,
            0, 0, 0, 1,
            0, 0, 3, 232,          // timescale 1000
            0, 0, 9, 196,          // earliest presentation time 2500
            0, 0, 0, 0,
            0, 0, 0, 1,
            0, 0, 0, 5, 0, 0, 3, 232, 0, 0, 0, 0,
        ])
        let index = try XCTUnwrap(SIDXIndex.parse(header))
        XCTAssertEqual(index.earliestPresentationTime, 2.5, accuracy: 0.000_1)
        let lyric = LyricPlaybackClock.lyricTime(
            playerTime: 10, anchor: .init(timelineOffset: index.earliestPresentationTime))
        XCTAssertEqual(lyric, 12.5, accuracy: 0.000_1)
    }

    private func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        precondition(payload.count < 127)
        return id + [0x80 | UInt8(payload.count)] + payload
    }
}
