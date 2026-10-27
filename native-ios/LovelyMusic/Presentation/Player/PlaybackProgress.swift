import Foundation

@MainActor @Observable
final class PlaybackProgress {
    private let audioEngine: AudioEngine

    var progress: Double {
        guard audioEngine.duration > 0 else { return 0 }
        return audioEngine.currentTime / audioEngine.duration
    }

    var currentTime: TimeInterval { audioEngine.currentTime }
    var duration: TimeInterval { audioEngine.duration }
    /// Seconds added to player time to reach the lyric timeline. AAC's sidx
    /// presentation time and an Opus file's container delay differ.
    var lyricTimelineOffset: TimeInterval { audioEngine.lyricTimelineOffset }
    var playingSourceID: String? {
        guard let song = audioEngine.currentTrack else { return nil }
        return audioEngine.playbackSourceID(for: song)
    }

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
}
