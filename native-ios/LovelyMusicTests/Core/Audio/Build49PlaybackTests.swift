import XCTest
@testable import LovelyMusic

/// Continuous karaoke sweep, shared progress-bar gradient, and the locked-screen display link.
final class Build49PlaybackTests: XCTestCase {
    func testSweepMovesInsideACharacterInsteadOfJumping() {
        let text = "Hello world"
        let before = LyricPlaybackClock.lyricSweep(text: text, lineStart: 0, lineEnd: 2, lyricTime: 1)
        let after = LyricPlaybackClock.lyricSweep(text: text, lineStart: 0, lineEnd: 2, lyricTime: 1.03)
        XCTAssertEqual(before.fraction, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(before.characterPosition, 5.5, accuracy: 0.000_1)
        XCTAssertGreaterThan(after.characterPosition, before.characterPosition)
        XCTAssertLessThan(after.characterPosition - before.characterPosition, 1, "a frame step stays inside one glyph")
        XCTAssertNotEqual(before.characterPosition, round(before.characterPosition), accuracy: 0.05)

        let beforeUnits = LyricPlaybackClock.sungUnits(text: text, lineStart: 0, lineEnd: 2, lyricTime: 1)
        let afterUnits = LyricPlaybackClock.sungUnits(text: text, lineStart: 0, lineEnd: 2, lyricTime: 1.03)
        XCTAssertEqual(beforeUnits.sungCharacters, afterUnits.sungCharacters, "the integer count holds while the edge keeps moving")

        let fills = LyricPlaybackClock.glyphFill(glyphCount: 11, sweep: before)
        XCTAssertEqual(fills[4], 1, accuracy: 0.000_1)
        XCTAssertEqual(fills[5], 0.5, accuracy: 0.000_1)
        XCTAssertEqual(fills[6], 0, accuracy: 0.000_1)

        let edge = LyricPlaybackClock.absoluteEdge(
            minXs: [0, 12, 30], maxXs: [10, 22, 50], glyphPosition: 1.25)
        XCTAssertEqual(edge, 14.5, accuracy: 0.000_1)
        XCTAssertEqual(
            LyricPlaybackClock.absoluteEdge(minXs: [0, 12], maxXs: [10, 22], glyphPosition: 2),
            22,
            accuracy: 0.000_1
        )
    }

    func testLeadingEdgeIsFeatheredAndEarlierLinesStayFilled() {
        let sweep = LyricPlaybackClock.lyricSweep(text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: 1)
        XCTAssertGreaterThan(sweep.feather, 0)
        XCTAssertLessThan(sweep.feather, sweep.fraction)
        let stops = LyricPlaybackClock.sweepMaskStops(sweep)
        let locations = stops.map(\.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(stops.first?.opacity ?? -1, 1, accuracy: 0.000_1)
        XCTAssertEqual(stops.last?.opacity ?? -1, 0, accuracy: 0.000_1)
        XCTAssertTrue(stops.contains { $0.opacity > 0.15 && $0.opacity < 0.85 })
        let shoulders = LyricPlaybackClock.featherShoulders
        XCTAssertGreaterThan(shoulders[0].opacity, shoulders[1].opacity)

        let done = LyricPlaybackClock.lyricSweep(text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: 2)
        XCTAssertEqual(done.fraction, 1, accuracy: 0.000_1)
        XCTAssertEqual(done.feather, 0, accuracy: 0.000_1)
        XCTAssertTrue(LyricPlaybackClock.sweepMaskStops(done).allSatisfy { $0.opacity == 1 })

        let sung = LyricPlaybackClock.presentedSweep(
            role: .sung, text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: 0.1)
        XCTAssertEqual(sung.fraction, 1, accuracy: 0.000_1)
        XCTAssertEqual(sung.feather, 0, accuracy: 0.000_1)
        let upcoming = LyricPlaybackClock.presentedSweep(
            role: .upcoming, text: "Next", lineStart: 2, lineEnd: 4, lyricTime: 1)
        XCTAssertEqual(upcoming.fraction, 0, accuracy: 0.000_1)

        let wrapped = LyricPlaybackClock.LyricSweep(
            fraction: 5.2 / 11, feather: 1.35 / 11, characterPosition: 5.2)
        let lines = LyricPlaybackClock.lineReveals(glyphCounts: [4, 7], sweep: wrapped)
        XCTAssertEqual(lines[0].edge, 4, accuracy: 0.000_1, "the first visual line stays filled")
        XCTAssertEqual(lines[0].feather, 0.15, accuracy: 0.000_1)
        XCTAssertEqual(lines[1].edge, 1.2, accuracy: 0.000_1)
        XCTAssertEqual(lines[1].feather, 1.2, accuracy: 0.000_1)

        var previous = -1.0
        for step in stride(from: 0.0, through: 2.0, by: 0.05) {
            let fraction = LyricPlaybackClock.lyricSweep(
                text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: step).fraction
            XCTAssertGreaterThanOrEqual(fraction, previous)
            previous = fraction
        }
        XCTAssertEqual(
            LyricPlaybackClock.lyricSweep(text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: 2).fraction,
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            LyricPlaybackClock.lyricSweep(text: "Hello world", lineStart: 0, lineEnd: 2, lyricTime: .nan).fraction,
            0,
            accuracy: 0.000_1
        )
    }

    func testSweepStaysAlignedForOpus251AndAAC141Or140() throws {
        func format(_ itag: Int, _ mime: String, _ bitrate: Int) -> StreamFormat {
            StreamFormat(
                itag: itag, url: "https://audio.example/\(itag)", mimeType: mime, bitrate: bitrate,
                contentLength: "1000", quality: nil, audioQuality: nil, audioSampleRate: nil,
                audioChannels: 2, approxDurationMs: "200000", width: nil, height: nil)
        }
        let formats = [
            format(140, "audio/mp4", 130_485),
            format(141, "audio/mp4", 256_000),
            format(251, "audio/webm; codecs=\"opus\"", 160_000),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let high = try XCTUnwrap(AudioSourcePlan.select(from: data, quality: .high))
        XCTAssertEqual(high.opusUpgrade?.itag, 251)
        XCTAssertEqual(high.aacFallback.itag, 141)
        let medium = try XCTUnwrap(AudioSourcePlan.select(from: data, quality: .medium))
        XCTAssertEqual(medium.aacFallback.itag, 140, "medium fallback stays on AAC 140")
        XCTAssertEqual(medium.opusUpgrade?.itag, 251)
        XCTAssertNotEqual(high.startup.itag, 251, "Opus is an upgrade, not the start path")

        let text = "Hello world"
        let video = 8.25
        let aacOffset = 2112.0 / 44100.0
        let opusOffset = 312.0 / 48_000.0
        func sweep(offset: TimeInterval, playingDuration: TimeInterval = 200) -> LyricPlaybackClock.LyricSweep {
            let anchor = LyricPlaybackClock.Anchor(
                timelineOffset: offset, timelineDuration: 200, playingDuration: playingDuration,
                authoredForPlayingSource: true)
            let lyric = LyricPlaybackClock.lyricTime(playerTime: video - offset, anchor: anchor)
            return LyricPlaybackClock.lyricSweep(text: text, lineStart: 6, lineEnd: 10, lyricTime: lyric)
        }
        let aac141 = sweep(offset: aacOffset)
        let opus251 = sweep(offset: opusOffset, playingDuration: 205)
        XCTAssertEqual(aac141.fraction, opus251.fraction, accuracy: 0.000_1)
        XCTAssertEqual(aac141.characterPosition, opus251.characterPosition, accuracy: 0.000_1)
        XCTAssertEqual(aac141.characterPosition, 6.1875, accuracy: 0.000_1)
        XCTAssertNotEqual(aac141.characterPosition, floor(aac141.characterPosition), accuracy: 0.02)
        // AAC 140 uses the same presentation delay as 141, so the fallback does not move the edge.
        XCTAssertEqual(sweep(offset: aacOffset).fraction, aac141.fraction, accuracy: 0.000_1)
        let stretched = LyricPlaybackClock.lyricTime(
            playerTime: video - aacOffset,
            anchor: .init(timelineOffset: aacOffset, timelineDuration: 180, playingDuration: 240,
                          authoredForPlayingSource: true))
        let straight = LyricPlaybackClock.lyricTime(
            playerTime: video - aacOffset,
            anchor: .init(timelineOffset: aacOffset, timelineDuration: 200, playingDuration: 200,
                          authoredForPlayingSource: true))
        XCTAssertEqual(
            LyricPlaybackClock.lyricSweep(text: text, lineStart: 6, lineEnd: 10, lyricTime: stretched).fraction,
            LyricPlaybackClock.lyricSweep(text: text, lineStart: 6, lineEnd: 10, lyricTime: straight).fraction,
            accuracy: 0.000_1
        )
    }

    func testLyricFillUsesThePlaybackProgressGradient() {
        XCTAssertEqual(PlaybackFillGradient.paletteHexes, ["#C174FF", "#729EFF", "#84DFFF"])
        XCTAssertEqual(LyricFillStyle.paletteHexes, PlaybackFillGradient.paletteHexes)
        XCTAssertEqual(
            PlaybackFillGradient.travelingHexes,
            PlaybackFillGradient.paletteHexes
                + PlaybackFillGradient.paletteHexes
                + [PlaybackFillGradient.paletteHexes[0]]
        )
    }

    func testPerFrameSweepStaysOffWhenTheScreenIsLocked() {
        XCTAssertTrue(PlaybackInterfaceBudget.animationsPaused(sceneIsActive: false))
        XCTAssertFalse(LyricSweepAnimation.isScheduled(
            sceneIsActive: false, isPlaying: true, reduceMotion: false, isCurrentLine: true))
        XCTAssertFalse(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: true, reduceMotion: false, isCurrentLine: false))
        XCTAssertFalse(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: false, reduceMotion: false, isCurrentLine: true))
        XCTAssertFalse(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: true, reduceMotion: true, isCurrentLine: true))
        XCTAssertTrue(LyricSweepAnimation.isScheduled(
            sceneIsActive: true, isPlaying: true, reduceMotion: false, isCurrentLine: true))
    }
}
