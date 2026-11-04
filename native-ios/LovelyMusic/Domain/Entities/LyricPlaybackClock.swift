import Foundation

/// Maps AVPlayer time onto the timeline lyric files were written for.
///
/// The loopback HLS playlist starts at the first audio sample. YouTube's sidx
/// `earliest_presentation_time` is that sample's position on the video timeline
/// and was previously discarded, so every cue was early by a constant. AAC and
/// Opus containers carry different presentation delays, so the same lyrics
/// drifted again when the playing source changed. Seek and background resume
/// stay correct because the mapping uses only player time plus that constant,
/// never wall-clock time.
enum LyricPlaybackClock {
    struct Anchor: Equatable, Sendable {
        var timelineOffset: TimeInterval = 0
        /// Length the cues were written for, when the provider reported one.
        var timelineDuration: TimeInterval?
        /// Length of the media that is actually playing.
        var playingDuration: TimeInterval?
        /// YouTube Music cues fetched for this exact playing video.
        var authoredForPlayingSource: Bool = false

        static let player = Anchor()
    }

    /// Lyric-file time corresponding to `playerTime`.
    ///
    /// Durations are not used to stretch cues. A recording whose length differs
    /// by more than a couple of seconds is a different timeline; the lookup
    /// keeps the cues authored for the source that is playing instead of
    /// warping one into the other. `authoredForPlayingSource` selects that
    /// path and still shares this offset so Opus and AAC land on the same cue.
    static func lyricTime(playerTime: TimeInterval, anchor: Anchor) -> TimeInterval {
        guard playerTime.isFinite else { return 0 }
        let offset = anchor.timelineOffset.isFinite ? anchor.timelineOffset : 0
        // `timelineDuration` / `authoredForPlayingSource` decide which file was
        // fetched. They must not stretch cues: a 5 s outro would slide every line.
        let time = playerTime + offset
        return time.isFinite ? max(0, time) : 0
    }

    /// Last cue whose timestamp is at or before `lyricTime`.
    static func activeLineIndex(times: [TimeInterval], lyricTime: TimeInterval) -> Int? {
        guard lyricTime.isFinite else { return nil }
        var active: Int?
        for (index, time) in times.enumerated() where time.isFinite && time <= lyricTime + 0.000_5 {
            active = index
        }
        return active
    }

    struct LineCue: Equatable, Sendable {
        var time: TimeInterval
        var text: String
    }

    /// How a line is painted. Sung lines stay filled; only the active line advances.
    enum LineRole: Equatable, Sendable {
        case plain, upcoming, current, sung
    }

    struct SungUnits: Equatable, Sendable {
        var sungCharacters: Int
        var sungWords: Int
        var characterCount: Int
        var wordCount: Int
    }

    struct KaraokeFill: Equatable, Sendable {
        var activeLineIndex: Int?
        var units: SungUnits
    }

    static func role(lineIndex: Int, activeIndex: Int?, synced: Bool) -> LineRole {
        guard synced, let activeIndex else { return synced ? .upcoming : .plain }
        if lineIndex < activeIndex { return .sung }
        if lineIndex == activeIndex { return .current }
        return .upcoming
    }

    /// Completed-character count inside the active line. A word counts as sung
    /// once every character of that word has filled, so spaced text advances
    /// word by word and unspaced text (CJK) advances one character at a time.
    /// The on-screen fill does not use this count: `lyricSweep` moves inside a
    /// character. `lyricTime` must already be `lyricTime(playerTime:anchor:)`
    /// so Opus and AAC share one timeline.
    static func karaokeFill(
        lines: [LineCue],
        lyricTime: TimeInterval,
        trailingLineDuration: TimeInterval = 4
    ) -> KaraokeFill {
        guard let index = activeLineIndex(times: lines.map(\.time), lyricTime: lyricTime) else {
            return KaraokeFill(activeLineIndex: nil, units: .empty)
        }
        let start = lines[index].time
        let end = index + 1 < lines.count ? lines[index + 1].time : start + trailingLineDuration
        return KaraokeFill(
            activeLineIndex: index,
            units: sungUnits(text: lines[index].text, lineStart: start, lineEnd: end, lyricTime: lyricTime)
        )
    }

    static func sungUnits(
        text: String,
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        lyricTime: TimeInterval
    ) -> SungUnits {
        let characters = Array(text)
        let words = wordRanges(in: text)
        let span = max(lineEnd - lineStart, 0.001)
        let sungCharacters = Self.sungCharacterCount(
            count: characters.count, lineStart: lineStart, span: span, lyricTime: lyricTime)
        let sungWords = words.filter { $0.upperBound <= sungCharacters }.count
        return SungUnits(
            sungCharacters: sungCharacters,
            sungWords: sungWords,
            characterCount: characters.count,
            wordCount: words.count
        )
    }

    /// How many characters have been reached. Each character owns an equal slice
    /// of the line. The slice boundary is compared directly so `span * 1 / n`
    /// does not collapse to the previous character through floating-point floor.
    private static func sungCharacterCount(
        count: Int, lineStart: TimeInterval, span: TimeInterval, lyricTime: TimeInterval
    ) -> Int {
        guard count > 0, lyricTime.isFinite else { return 0 }
        let elapsed = lyricTime - lineStart
        if elapsed >= span { return count }
        if elapsed <= 0 { return 0 }
        var sung = 0
        for index in 1...count {
            let boundary = lineStart + span * Double(index) / Double(count)
            if lyricTime + 0.000_5 >= boundary {
                sung = index
            } else {
                break
            }
        }
        return sung
    }

    /// Whitespace-delimited words. Without spaces each character is a word.
    static func wordRanges(in text: String) -> [Range<Int>] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        let hasWhitespace = characters.contains { $0.isWhitespace }
        if !hasWhitespace {
            return characters.indices.map { $0..<$0 + 1 }
        }
        var ranges: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            let start = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            if start < index { ranges.append(start..<index) }
        }
        return ranges
    }

    /// Continuous position of the karaoke leading edge. `fraction` is the
    /// portion of the line (0...1) and is not rounded to a character.
    /// `characterPosition` is that edge in character units, so 5.4 means the
    /// edge is 40% of the way through the sixth character.
    struct LyricSweep: Equatable, Sendable {
        var fraction: Double
        var feather: Double
        var characterPosition: Double

        static let empty = LyricSweep(fraction: 0, feather: 0, characterPosition: 0)
    }

    /// Soft falloff behind the leading edge, as a fraction of the line.
    /// About one glyph wide, clamped so a short line does not dissolve entirely.
    static let featherGlyphs: Double = 1.35
    static let featherMinimum: Double = 0.035
    static let featherMaximum: Double = 0.16

    struct FeatherShoulder: Equatable, Sendable {
        var position: Double
        var opacity: Double
    }

    /// Opacity samples from the solid fill to the clear edge. Shared by the
    /// mask so the leading edge feathers instead of cutting a glyph in half.
    static let featherShoulders: [FeatherShoulder] = [
        .init(position: 0.42, opacity: 0.62),
        .init(position: 0.75, opacity: 0.22),
    ]

    struct SweepMaskStop: Equatable, Sendable {
        var location: Double
        var opacity: Double
    }

    struct LineReveal: Equatable, Sendable {
        var edge: Double
        var feather: Double
        var glyphCount: Int
    }

    /// Sweep for one line of text. Time moves linearly across the line, which
    /// is sub-character: a 20 ms step is a fraction of a glyph, not a whole one.
    static func lyricSweep(
        text: String,
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        lyricTime: TimeInterval
    ) -> LyricSweep {
        let count = text.count
        let fraction = sweepFraction(lineStart: lineStart, lineEnd: lineEnd, lyricTime: lyricTime)
        return LyricSweep(
            fraction: fraction,
            feather: featherFraction(characterCount: count, fraction: fraction),
            characterPosition: Double(count) * fraction
        )
    }

    /// What the row actually paints. Earlier lines stay full. Later lines stay
    /// empty. Only the active line tracks the clock.
    static func presentedSweep(
        role: LineRole,
        text: String,
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        lyricTime: TimeInterval
    ) -> LyricSweep {
        switch role {
        case .sung:
            return LyricSweep(fraction: 1, feather: 0, characterPosition: Double(text.count))
        case .upcoming, .plain:
            return .empty
        case .current:
            return lyricSweep(text: text, lineStart: lineStart, lineEnd: lineEnd, lyricTime: lyricTime)
        }
    }

    static func featherFraction(characterCount: Int, fraction: Double) -> Double {
        guard characterCount > 0 else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0, clamped < 1 else { return 0 }
        let one = 1 / Double(characterCount)
        let desired = min(max(one * featherGlyphs, featherMinimum), featherMaximum)
        return min(desired, clamped)
    }

    /// 0...1 coverage of each glyph. A value strictly between 0 and 1 is the
    /// leading edge sitting inside that glyph.
    static func glyphFill(glyphCount: Int, sweep: LyricSweep) -> [Double] {
        guard glyphCount > 0 else { return [] }
        let edge = min(max(sweep.fraction, 0), 1) * Double(glyphCount)
        return (0..<glyphCount).map { index in
            let start = Double(index)
            if edge >= start + 1 { return 1 }
            if edge <= start { return 0 }
            return edge - start
        }
    }

    /// Split a sweep across wrapped visual lines, in reading order. A line the
    /// edge has already left stays filled; the feather can still soften its tail.
    static func lineReveals(glyphCounts: [Int], sweep: LyricSweep) -> [LineReveal] {
        let total = glyphCounts.reduce(0, +)
        guard total > 0 else {
            return glyphCounts.map { LineReveal(edge: 0, feather: 0, glyphCount: $0) }
        }
        let edge = min(max(sweep.fraction, 0), 1) * Double(total)
        let feather = min(max(sweep.feather, 0), sweep.fraction) * Double(total)
        let featherStart = max(0, edge - feather)
        var cursor = 0.0
        return glyphCounts.map { count in
            let start = cursor
            let end = cursor + Double(count)
            cursor = end
            let localEdge = min(max(edge, start), end) - start
            let localFeatherStart = min(max(featherStart, start), end) - start
            return LineReveal(
                edge: localEdge,
                feather: max(0, localEdge - localFeatherStart),
                glyphCount: count
            )
        }
    }

    /// X of the leading edge from per-glyph bounds. `glyphPosition` may be fractional.
    static func absoluteEdge(minXs: [Double], maxXs: [Double], glyphPosition: Double) -> Double {
        guard !minXs.isEmpty, minXs.count == maxXs.count else { return 0 }
        if glyphPosition <= 0 { return minXs[0] }
        if glyphPosition >= Double(minXs.count) { return maxXs[minXs.count - 1] }
        let index = min(minXs.count - 1, max(0, Int(glyphPosition)))
        let partial = min(max(glyphPosition - Double(index), 0), 1)
        return minXs[index] + (maxXs[index] - minXs[index]) * partial
    }

    static func sweepMaskStops(_ sweep: LyricSweep) -> [SweepMaskStop] {
        sweepMaskStops(edge: sweep.fraction, feather: sweep.feather)
    }

    /// Unit-space mask. Location 0 is the start of the revealed span and
    /// `edge` is where the fill becomes clear. Shoulders soften that point.
    static func sweepMaskStops(edge: Double, feather: Double) -> [SweepMaskStop] {
        let clampedEdge = min(max(edge, 0), 1)
        if clampedEdge <= 0 {
            return [
                SweepMaskStop(location: 0, opacity: 0),
                SweepMaskStop(location: 1, opacity: 0),
            ]
        }
        let width = min(max(feather, 0), clampedEdge)
        if clampedEdge >= 1, width <= 0 {
            return [
                SweepMaskStop(location: 0, opacity: 1),
                SweepMaskStop(location: 1, opacity: 1),
            ]
        }
        let solid = clampedEdge - width
        var stops: [SweepMaskStop] = [
            SweepMaskStop(location: 0, opacity: 1),
            SweepMaskStop(location: solid, opacity: 1),
        ]
        for shoulder in featherShoulders {
            stops.append(SweepMaskStop(
                location: solid + width * shoulder.position,
                opacity: shoulder.opacity
            ))
        }
        stops.append(SweepMaskStop(location: clampedEdge, opacity: 0))
        stops.append(SweepMaskStop(location: 1, opacity: 0))
        var previous = 0.0
        for index in stops.indices {
            let location = min(max(stops[index].location, previous), 1)
            stops[index].location = location
            previous = location
        }
        return stops
    }

    private static func sweepFraction(
        lineStart: TimeInterval, lineEnd: TimeInterval, lyricTime: TimeInterval
    ) -> Double {
        guard lyricTime.isFinite, lineStart.isFinite, lineEnd.isFinite else { return 0 }
        let span = max(lineEnd - lineStart, 0.001)
        let elapsed = lyricTime - lineStart
        if elapsed <= 0 { return 0 }
        if elapsed >= span { return 1 }
        return elapsed / span
    }
}

/// Whether the current lyric row may run a display-linked sweep.
/// Locked and background scenes leave this false so the per-frame timeline
/// is not even mounted.
enum LyricSweepAnimation {
    static func isScheduled(
        sceneIsActive: Bool,
        isPlaying: Bool,
        reduceMotion: Bool,
        isCurrentLine: Bool
    ) -> Bool {
        isCurrentLine
            && isPlaying
            && !reduceMotion
            && !PlaybackInterfaceBudget.animationsPaused(sceneIsActive: sceneIsActive)
    }
}

extension LyricPlaybackClock.SungUnits {
    static let empty = Self(sungCharacters: 0, sungWords: 0, characterCount: 0, wordCount: 0)
}
