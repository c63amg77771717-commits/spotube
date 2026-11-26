import Foundation

/// Foreground versus locked-screen budgets for the playback UI clock.
///
/// Display-linked lyric, vinyl and progress animations are paused while the
/// scene is inactive. The audio clock keeps a 1 Hz sample so crossfade, stall
/// detection and an expired URL can still move, without a 10 Hz SwiftUI
/// invalidation or a 60 fps display link.
enum PlaybackInterfaceBudget {
    static let foregroundSampleSeconds: TimeInterval = 0.1
    static let backgroundSampleSeconds: TimeInterval = 1

    static func timeObserverInterval(interfaceActive: Bool) -> TimeInterval {
        interfaceActive ? foregroundSampleSeconds : backgroundSampleSeconds
    }

    static func animationsPaused(sceneIsActive: Bool, interfaceSuspended: Bool = false) -> Bool {
        !sceneIsActive || interfaceSuspended
    }

    struct ForegroundWarmth: Equatable, Sendable {
        /// Activate the audio session before the user taps play.
        var activateAudioSession: Bool
        /// Buffer a ready, unexpired item so the following play is a rate change.
        var prerollReadyItem: Bool
        /// Drop a signed URL that can no longer start, instead of handing it to AVPlayer.
        var dropExpiredItem: Bool
        /// Resolve a replacement URL while the song stays paused, so the next play
        /// does not wait on a cold lookup. This does not start audio or Opus.
        var warmExpiredSource: Bool
        /// Keep an AVPlayer allocated so the next item does not build the graph from scratch.
        var keepPlayerGraph: Bool
    }

    /// Lock-screen and headphone resume set the rate on the item already installed.
    /// A precise seek before that rate change is what made the first samples wait
    /// on the network. Stall recovery still handles an item that never advances.
    static func seeksBeforeResumeRate(resumeNeedsKick: Bool, playbackLikelyToKeepUp: Bool) -> Bool {
        _ = (resumeNeedsKick, playbackLikelyToKeepUp)
        return false
    }

    /// What to prepare when the phone leaves standby. Opus preparation is not
    /// part of this decision: AAC (or the file already playing) starts first.
    static func foregroundWarmth(
        returningFromBackground: Bool,
        hasTrack: Bool,
        isPlaying: Bool,
        userPaused: Bool,
        remoteExpired: Bool,
        otherAudioOwnsSession: Bool,
        itemReady: Bool
    ) -> ForegroundWarmth {
        guard returningFromBackground, hasTrack else {
            return ForegroundWarmth(
                activateAudioSession: false,
                prerollReadyItem: false,
                dropExpiredItem: false,
                warmExpiredSource: false,
                keepPlayerGraph: false
            )
        }
        let paused = !isPlaying || userPaused
        let canWarmSession = paused && !otherAudioOwnsSession
        let dropExpired = paused && remoteExpired
        return ForegroundWarmth(
            activateAudioSession: canWarmSession,
            prerollReadyItem: canWarmSession && itemReady && !remoteExpired,
            dropExpiredItem: dropExpired,
            warmExpiredSource: dropExpired,
            keepPlayerGraph: true
        )
    }
}
