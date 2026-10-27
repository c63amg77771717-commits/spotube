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
}
