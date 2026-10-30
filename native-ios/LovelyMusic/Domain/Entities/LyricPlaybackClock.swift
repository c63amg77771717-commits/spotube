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

    /// Character-by-character fill inside the active line. A word counts as sung
    /// once every character of that word has filled, so spaced text advances
    /// word by word and unspaced text (CJK) advances one character at a time.
    /// `lyricTime` must already be `lyricTime(playerTime:anchor:)` so Opus and
    /// AAC share one timeline.
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
        let fraction: Double
        if lyricTime.isFinite {
            fraction = min(1, max(0, (lyricTime - lineStart) / span))
        } else {
            fraction = 0
        }
        let sungCharacters = fraction >= 1
            ? characters.count
            : min(characters.count, Int((fraction * Double(characters.count)).rounded(.down)))
        let sungWords = words.filter { $0.upperBound <= sungCharacters }.count
        return SungUnits(
            sungCharacters: sungCharacters,
            sungWords: sungWords,
            characterCount: characters.count,
            wordCount: words.count
        )
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
}

extension LyricPlaybackClock.SungUnits {
    static let empty = Self(sungCharacters: 0, sungWords: 0, characterCount: 0, wordCount: 0)
}
