import XCTest
@testable import LovelyMusic

/// Background recovery bounds and lyric lines that sit in front of an interlude.
final class Build50PlaybackTests: XCTestCase {
    func testLongGapFillsTheLineThenLeavesItSungUntilTheNextCue() {
        let lines = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hello world"),
            LyricPlaybackClock.LineCue(time: 20, text: "After interlude"),
        ]
        let window = LyricPlaybackClock.lineWindow(lines: lines, index: 0)
        XCTAssertGreaterThan(window.end, 1.5)
        XCTAssertLessThanOrEqual(window.end, LyricPlaybackClock.interludeGapThreshold)
        XCTAssertLessThan(window.end, 8, "the sweep must not run for the whole interlude")

        let midpoint = LyricPlaybackClock.lyricSweep(
            text: lines[0].text, lineStart: window.start, lineEnd: window.end, lyricTime: window.end / 2)
        XCTAssertEqual(midpoint.fraction, 0.5, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(midpoint.fraction, 0)
        XCTAssertLessThanOrEqual(midpoint.fraction, 1)

        let during = LyricPlaybackClock.playbackFocus(lines: lines, lyricTime: 10)
        XCTAssertTrue(during.inInterlude)
        XCTAssertNil(during.activeLineIndex)
        XCTAssertEqual(during.sungThroughIndex, 0)
        XCTAssertNil(LyricPlaybackClock.karaokeFill(lines: lines, lyricTime: 10).activeLineIndex)
        XCTAssertEqual(
            LyricPlaybackClock.role(lineIndex: 0, activeIndex: nil, synced: true, sungThroughIndex: 0),
            .sung)
        XCTAssertEqual(
            LyricPlaybackClock.role(lineIndex: 1, activeIndex: nil, synced: true, sungThroughIndex: 0),
            .upcoming)

        let filled = LyricPlaybackClock.lyricSweep(
            text: lines[0].text, lineStart: window.start, lineEnd: window.end, lyricTime: 10)
        XCTAssertEqual(filled.fraction, 1, accuracy: 0.000_1)
        let before = LyricPlaybackClock.lyricSweep(
            text: lines[0].text, lineStart: window.start, lineEnd: window.end, lyricTime: -2)
        XCTAssertEqual(before.fraction, 0, accuracy: 0.000_1)

        let stillWaiting = LyricPlaybackClock.playbackFocus(lines: lines, lyricTime: 19.9)
        XCTAssertNil(stillWaiting.activeLineIndex)
        XCTAssertTrue(stillWaiting.inInterlude)
        let next = LyricPlaybackClock.playbackFocus(lines: lines, lyricTime: 20)
        XCTAssertEqual(next.activeLineIndex, 1)
        XCTAssertFalse(next.inInterlude)
    }

    func testSyllableEndsCapTheLineAndAShortGapDoesNot() {
        let timed = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hello world", syllableEnds: [1.1, 2.4]),
            LyricPlaybackClock.LineCue(time: 18, text: "Next"),
        ]
        let timedWindow = LyricPlaybackClock.lineWindow(lines: timed, index: 0)
        XCTAssertEqual(timedWindow.end, 2.4, accuracy: 0.000_1)
        let gap = LyricPlaybackClock.playbackFocus(lines: timed, lyricTime: 8)
        XCTAssertTrue(gap.inInterlude)
        XCTAssertNil(gap.activeLineIndex)
        XCTAssertEqual(
            LyricPlaybackClock.playbackFocus(lines: timed, lyricTime: 18).activeLineIndex, 1)

        let close = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hello world"),
            LyricPlaybackClock.LineCue(time: 2, text: "下一句歌詞"),
            LyricPlaybackClock.LineCue(time: 4, text: "End"),
        ]
        XCTAssertEqual(LyricPlaybackClock.lineWindow(lines: close, index: 0).end, 2, accuracy: 0.000_1)
        XCTAssertEqual(LyricPlaybackClock.lineWindow(lines: close, index: 1).end, 4, accuracy: 0.000_1)
        let halfway = LyricPlaybackClock.karaokeFill(lines: close, lyricTime: 1)
        XCTAssertEqual(halfway.activeLineIndex, 0)
        XCTAssertEqual(halfway.units.sungCharacters, 5)
        XCTAssertFalse(LyricPlaybackClock.playbackFocus(lines: close, lyricTime: 1).inInterlude)
    }

    func testNeighboringLinesSetTheCapAndBothSourcesShareTheInterlude() {
        let lines = [
            LyricPlaybackClock.LineCue(time: 0, text: "Hi"),
            LyricPlaybackClock.LineCue(time: 2, text: "Hello world"),
            LyricPlaybackClock.LineCue(time: 32, text: "Tail"),
        ]
        let window = LyricPlaybackClock.lineWindow(lines: lines, index: 1)
        XCTAssertEqual(window.end, 6.5, accuracy: 0.000_1, "2s neighbors scaled by text length, then clamped")
        XCTAssertTrue(LyricPlaybackClock.playbackFocus(lines: lines, lyricTime: 10).inInterlude)
        XCTAssertEqual(
            LyricPlaybackClock.playbackFocus(lines: lines, lyricTime: 32).activeLineIndex, 2)

        let bridge = [
            LyricPlaybackClock.LineCue(time: 10, text: "Hello"),
            LyricPlaybackClock.LineCue(time: 40, text: "After"),
        ]
        let aacOffset = 2112.0 / 44100.0
        let opusOffset = 312.0 / 48000.0
        let video = 25.0
        let aac = LyricPlaybackClock.Anchor(
            timelineOffset: aacOffset, timelineDuration: 200, playingDuration: 200,
            authoredForPlayingSource: true)
        let opus = LyricPlaybackClock.Anchor(
            timelineOffset: opusOffset, timelineDuration: 200, playingDuration: 205,
            authoredForPlayingSource: true)
        let aacLyric = LyricPlaybackClock.lyricTime(playerTime: video - aacOffset, anchor: aac)
        let opusLyric = LyricPlaybackClock.lyricTime(playerTime: video - opusOffset, anchor: opus)
        XCTAssertEqual(aacLyric, opusLyric, accuracy: 0.000_1)
        XCTAssertEqual(
            LyricPlaybackClock.playbackFocus(lines: bridge, lyricTime: aacLyric),
            LyricPlaybackClock.playbackFocus(lines: bridge, lyricTime: opusLyric))
        XCTAssertTrue(LyricPlaybackClock.playbackFocus(lines: bridge, lyricTime: aacLyric).inInterlude)
    }

    func testStallFallsBackFromOpusThenBacksOffAndSkips() {
        var budget = LockedScreenPlaybackRecovery()
        XCTAssertEqual(budget.action(playingOpus: true, hasAACFallback: true), .fallBackToAAC)
        budget.noteFallback()
        XCTAssertEqual(budget.resolveAttempts, 0, "switching to AAC is not a network resolve")
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: true), .retryAfter(1))

        budget.noteRetryScheduled()
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .waitForInFlight)
        budget.noteResolveStarted()
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .waitForInFlight)
        budget.noteResolveFinished()

        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .retryAfter(2))
        budget.noteRetryScheduled()
        budget.noteResolveStarted()
        budget.noteResolveFinished()
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .retryAfter(4))
        budget.noteRetryScheduled()
        budget.noteResolveStarted()
        budget.noteResolveFinished()
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .skip)
        XCTAssertEqual(budget.resolveAttempts, LockedScreenPlaybackRecovery.maximumResolveAttempts)
    }

    func testRecoveredPlaybackDuringBackoffDoesNotSpendTheAttempt() {
        var budget = LockedScreenPlaybackRecovery()
        _ = budget.action(playingOpus: false, hasAACFallback: false)
        budget.noteRetryScheduled()
        budget.noteBackoffCancelled()
        XCTAssertEqual(budget.resolveAttempts, 0)
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .retryAfter(1))
    }

    @MainActor
    func testBackgroundSuspendDetachesTheVideoPlayer() {
        let manager = VideoPlaybackManager()
        manager.installPlayerForTesting()
        XCTAssertNotNil(manager.videoPlayer)
        XCTAssertFalse(manager.isVideoSuspended)
        manager.suspendForBackground()
        XCTAssertNil(manager.videoPlayer)
        XCTAssertNil(manager.videoPlayerItem)
        XCTAssertTrue(manager.isVideoSuspended)
        manager.suspendForBackground()
        XCTAssertTrue(manager.isVideoSuspended)
    }

    func testLockedScreenStopsDisplayLinkedLyricSweep() {
        XCTAssertTrue(PlaybackInterfaceBudget.animationsPaused(
            sceneIsActive: true, interfaceSuspended: true))
        XCTAssertFalse(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: true, reduceMotion: false, isCurrentLine: true,
            interfaceSuspended: true))
        XCTAssertTrue(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: true, reduceMotion: false, isCurrentLine: true,
            interfaceSuspended: false))
    }
}
