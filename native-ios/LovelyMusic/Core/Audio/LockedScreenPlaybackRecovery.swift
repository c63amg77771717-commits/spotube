import Foundation

/// What to do after a stall or a failed start, including while the screen is locked.
///
/// One video has a single in-flight resolve. Further failures wait out an
/// exponential backoff, and a track that still will not play is skipped.
/// Opus is dropped for the retained AAC source before any of those resolves.
struct LockedScreenPlaybackRecovery: Equatable, Sendable {
    static let maximumResolveAttempts = 3

    private(set) var resolveAttempts = 0
    private(set) var fellBackFromOpus = false
    private(set) var resolveInFlight = false
    private(set) var waitingForBackoff = false

    enum Action: Equatable, Sendable {
        case fallBackToAAC
        case retryAfter(TimeInterval)
        case skip
        case waitForInFlight
    }

    func action(playingOpus: Bool, hasAACFallback: Bool) -> Action {
        if resolveInFlight || waitingForBackoff { return .waitForInFlight }
        if playingOpus && hasAACFallback && !fellBackFromOpus {
            return .fallBackToAAC
        }
        if resolveAttempts >= Self.maximumResolveAttempts {
            return .skip
        }
        let exponent = min(resolveAttempts, 4)
        return .retryAfter(pow(2, Double(exponent)))
    }

    mutating func noteFallback() {
        fellBackFromOpus = true
    }

    mutating func noteRetryScheduled() {
        waitingForBackoff = true
        resolveAttempts += 1
    }

    mutating func noteResolveStarted() {
        waitingForBackoff = false
        resolveInFlight = true
    }

    /// The item started during the wait, so this scheduled resolve is not spent.
    mutating func noteBackoffCancelled() {
        waitingForBackoff = false
        if !resolveInFlight, resolveAttempts > 0 {
            resolveAttempts -= 1
        }
    }

    mutating func noteResolveFinished() {
        resolveInFlight = false
        waitingForBackoff = false
    }

    mutating func reset() {
        self = LockedScreenPlaybackRecovery()
    }
}
