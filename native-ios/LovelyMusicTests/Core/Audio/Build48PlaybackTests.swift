import MediaPlayer
import XCTest
@testable import LovelyMusic

/// Karaoke fill, translation size, background budget, standby warmth, and diagnostics.
final class Build48PlaybackTests: XCTestCase {
    func testKaraokeFillsCharactersThenWordsAndKeepsEarlierLinesSung() {
        let lines = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hello world"),
            LyricPlaybackClock.LineCue(time: 2, text: "下一句歌詞"),
            LyricPlaybackClock.LineCue(time: 4, text: "End"),
        ]
        let before = LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: -0.2)
        XCTAssertNil(before.activeLineIndex)
        XCTAssertEqual(before.units.sungCharacters, 0)

        let halfway = LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: 1)
        XCTAssertEqual(halfway.activeLineIndex, 0)
        XCTAssertEqual(halfway.units.characterCount, 11)
        XCTAssertEqual(halfway.units.sungCharacters, 5)
        XCTAssertEqual(halfway.units.wordCount, 2)
        XCTAssertEqual(halfway.units.sungWords, 1, "Hello is complete; world has not started")
        XCTAssertEqual(LyricPlaybackClock.role(lineIndex: 0, activeIndex: 0, synced: true), .current)
        XCTAssertEqual(LyricPlaybackClock.role(lineIndex: 1, activeIndex: 0, synced: true), .upcoming)

        let intoSecond = LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: 2 + (2.0 / 5.0))
        XCTAssertEqual(intoSecond.activeLineIndex, 1)
        XCTAssertEqual(intoSecond.units.characterCount, 5)
        XCTAssertEqual(intoSecond.units.wordCount, 5, "unspaced CJK advances one character per word")
        XCTAssertEqual(intoSecond.units.sungCharacters, 1)
        XCTAssertEqual(intoSecond.units.sungWords, 1)
        XCTAssertEqual(LyricPlaybackClock.role(lineIndex: 0, activeIndex: 1, synced: true), .sung)
        XCTAssertEqual(LyricPlaybackClock.role(lineIndex: 1, activeIndex: 1, synced: true), .current)

        let done = LyricPlaybackClock.sungUnits(text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: 2)
        XCTAssertEqual(done.sungCharacters, done.characterCount)
        XCTAssertEqual(done.sungWords, done.wordCount)
    }

    func testKaraokeFillMatchesAcrossOpusAndAACOffsets() {
        let lines = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hello world"),
            LyricPlaybackClock.LineCue(time: 2, text: "Next"),
        ]
        let aacOffset = 2112.0 / 44100.0
        let opusOffset = 312.0 / 48000.0
        let video = 1.25
        let aac = LyricPlaybackClock.Anchor(
            timelineOffset: aacOffset, timelineDuration: 200, playingDuration: 200, authoredForPlayingSource: true)
        let opus = LyricPlaybackClock.Anchor(
            timelineOffset: opusOffset, timelineDuration: 200, playingDuration: 205, authoredForPlayingSource: true)
        let aacLyric = LyricPlaybackClock.lyricTime(playerTime: video - aacOffset, anchor: aac)
        let opusLyric = LyricPlaybackClock.lyricTime(playerTime: video - opusOffset, anchor: opus)
        XCTAssertEqual(aacLyric, opusLyric, accuracy: 0.000_1)
        XCTAssertEqual(
            LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: aacLyric),
            LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: opusLyric)
        )
        let stretched = LyricPlaybackClock.lyricTime(
            playerTime: video - aacOffset,
            anchor: .init(timelineOffset: aacOffset, timelineDuration: 180, playingDuration: 240))
        XCTAssertEqual(
            LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: stretched),
            LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: aacLyric)
        )
    }

    func testTranslatedLyricsAreAtLeastTwoStepsLarger() {
        for preference in LyricsFontSize.allCases {
            let rank = LyricsTranslationTypography.rank(for: preference)
            let previous = LyricsTranslationTypography.previousCaptionRank(for: preference)
            XCTAssertGreaterThanOrEqual(rank, previous + 2)
        }
        XCTAssertLessThan(
            LyricsTranslationTypography.rank(for: .small),
            LyricsTranslationTypography.rank(for: .medium)
        )
        XCTAssertLessThan(
            LyricsTranslationTypography.rank(for: .medium),
            LyricsTranslationTypography.rank(for: .large)
        )
    }

    func testBackgroundSamplingIsSlowerAndAnimationsPauseOffscreen() {
        let foreground = PlaybackInterfaceBudget.timeObserverInterval(interfaceActive: true)
        let background = PlaybackInterfaceBudget.timeObserverInterval(interfaceActive: false)
        XCTAssertLessThanOrEqual(foreground, 0.25)
        XCTAssertGreaterThanOrEqual(background, 1)
        XCTAssertLessThan(foreground, background)
        XCTAssertTrue(PlaybackInterfaceBudget.animationsPaused(sceneIsActive: false))
        XCTAssertFalse(PlaybackInterfaceBudget.animationsPaused(sceneIsActive: true))
    }

    func testStandbyWarmthActivatesSessionWithoutTouchingOpusOrOtherAudio() {
        let idle = PlaybackInterfaceBudget.foregroundWarmth(
            returningFromBackground: false, hasTrack: true, isPlaying: false, userPaused: true,
            remoteExpired: true, otherAudioOwnsSession: false, itemReady: true)
        XCTAssertFalse(idle.activateAudioSession)
        XCTAssertFalse(idle.keepPlayerGraph)

        let ready = PlaybackInterfaceBudget.foregroundWarmth(
            returningFromBackground: true, hasTrack: true, isPlaying: false, userPaused: true,
            remoteExpired: false, otherAudioOwnsSession: false, itemReady: true)
        XCTAssertTrue(ready.activateAudioSession)
        XCTAssertTrue(ready.prerollReadyItem)
        XCTAssertFalse(ready.dropExpiredItem)
        XCTAssertTrue(ready.keepPlayerGraph)

        let stale = PlaybackInterfaceBudget.foregroundWarmth(
            returningFromBackground: true, hasTrack: true, isPlaying: false, userPaused: true,
            remoteExpired: true, otherAudioOwnsSession: false, itemReady: true)
        XCTAssertTrue(stale.dropExpiredItem)
        XCTAssertFalse(stale.prerollReadyItem)
        XCTAssertTrue(stale.activateAudioSession)

        let playing = PlaybackInterfaceBudget.foregroundWarmth(
            returningFromBackground: true, hasTrack: true, isPlaying: true, userPaused: false,
            remoteExpired: false, otherAudioOwnsSession: false, itemReady: true)
        XCTAssertFalse(playing.activateAudioSession)
        XCTAssertFalse(playing.prerollReadyItem)
        XCTAssertFalse(playing.dropExpiredItem)

        let someoneElse = PlaybackInterfaceBudget.foregroundWarmth(
            returningFromBackground: true, hasTrack: true, isPlaying: false, userPaused: true,
            remoteExpired: false, otherAudioOwnsSession: true, itemReady: true)
        XCTAssertFalse(someoneElse.activateAudioSession)
        XCTAssertFalse(someoneElse.prerollReadyItem)
    }

    func testRemoteCommandHandlerFinishesBeforeTheCallReturns() {
        var ran = false
        let status = MainActorRemoteCommand.run { ran = true }
        XCTAssertEqual(status, .success)
        XCTAssertTrue(ran)
        XCTAssertEqual(MainActorRemoteCommand.run(nil), .commandFailed)

        let finished = expectation(description: "background command")
        var order: [String] = []
        let lock = NSLock()
        DispatchQueue.global(qos: .userInitiated).async {
            let backgroundStatus = MainActorRemoteCommand.run {
                lock.lock()
                order.append("handler")
                lock.unlock()
            }
            lock.lock()
            order.append("returned")
            lock.unlock()
            XCTAssertEqual(backgroundStatus, .success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(order, ["handler", "returned"])
    }

    func testRuntimeLogStripsURLsAndSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("build48-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("RuntimeDiagnostics.log")
        let log = RuntimeDiagnosticLog(fileURL: file)
        log.append("crash https://rr.googlevideo.com/videoplayback?expire=1&sig=SECRET")
        let line = try XCTUnwrap(log.snapshot().first)
        XCTAssertFalse(line.contains("https://"))
        XCTAssertFalse(line.contains("SECRET"))
        XCTAssertTrue(line.contains("[url]"))
        let restored = RuntimeDiagnosticLog(fileURL: file)
        XCTAssertEqual(restored.snapshot(), log.snapshot())
        XCTAssertEqual(
            MetricKitDiagnosticSummary.payloadLine(crashCount: 1, cpuCount: 2, hangCount: 0, diskWriteCount: 0),
            "metrickit payload crashes=1 cpu=2 hangs=0 disk=0"
        )
        XCTAssertTrue(
            MetricKitDiagnosticSummary.crashLine(
                exceptionType: 10, exceptionCode: 0, signal: 9, terminationReason: "https://example.test/x"
            ).contains("[url]")
        )
    }
}
