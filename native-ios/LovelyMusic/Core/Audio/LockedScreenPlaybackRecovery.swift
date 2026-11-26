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

    /// The item actually advanced during the wait, so this scheduled resolve is not spent.
    /// A status of `.playing` with the position still at zero is the stuck loop:
    /// refunding that attempt kept the same video on a one-second resolve forever.
    mutating func noteBackoffCancelled(timeAdvanced: Bool = true) {
        waitingForBackoff = false
        guard timeAdvanced, !resolveInFlight, resolveAttempts > 0 else { return }
        resolveAttempts -= 1
    }

    mutating func noteResolveFinished() {
        resolveInFlight = false
        waitingForBackoff = false
    }

    mutating func reset() {
        self = LockedScreenPlaybackRecovery()
    }
}

/// LOGIN_REQUIRED stays paused until the listener picks another upload or skips.
enum ListenerPlaybackChoice {
    static func isSignInRequired(_ message: String) -> Bool {
        let value = message.lowercased()
        if value.contains("login_required") || value.contains("signinrequired") { return true }
        if value.contains("authentication required") || value.contains("confirm your age") { return true }
        if value.contains("sign in") || value.contains("登入") { return true }
        return false
    }

    static func allowsAutomaticAdvance(signInRequired: Bool, userInitiated: Bool) -> Bool {
        userInitiated || !signInRequired
    }
}

/// Unexpected pause observations share one clock. A burst of identical KVO
/// callbacks must not schedule another retry or write another diagnostic line.
struct UnexpectedPauseAdmission: Equatable, Sendable {
    var kicks = 0
    var lastDecision: TimeInterval = -.greatestFiniteMagnitude
    var minimumSpacing: TimeInterval = 1
    var maximumRecoveries = 2

    enum Decision: Equatable, Sendable {
        case kick
        case recover
        case ignore
    }

    mutating func admit(now: TimeInterval, recoveryBusy: Bool) -> Decision {
        if recoveryBusy { return .ignore }
        if kicks == 0 {
            kicks = 1
            lastDecision = now
            return .kick
        }
        if now - lastDecision < minimumSpacing { return .ignore }
        if kicks > maximumRecoveries { return .ignore }
        kicks += 1
        lastDecision = now
        return .recover
    }

    mutating func reset() {
        kicks = 0
        lastDecision = -.greatestFiniteMagnitude
    }
}

/// Automatic resolves of one video id stay at least a couple of seconds apart.
/// An in-flight lookup never starts a second one.
struct AutomaticResolveGate: Equatable, Sendable {
    var last: [String: TimeInterval] = [:]
    var spacing: TimeInterval = 2

    mutating func allow(videoID: String, now: TimeInterval, inFlight: Bool) -> Bool {
        if inFlight { return false }
        if let previous = last[videoID], now - previous < spacing { return false }
        last[videoID] = now
        return true
    }
}
