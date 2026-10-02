import Foundation
import os

enum PlaybackRecoveryEvent: Equatable, Sendable {
    case stallDetected(trackID: String, position: TimeInterval)
    case loadingTimedOut(trackID: String)
}

@MainActor
protocol PlaybackRecoveryClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor
protocol PlaybackRecoveryScheduling: AnyObject {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ check: @escaping @MainActor () -> Void
    )
    func cancelRepeating()
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
private final class SystemPlaybackRecoveryClock: PlaybackRecoveryClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
private final class SystemPlaybackRecoveryScheduler: PlaybackRecoveryScheduling {
    private var timer: Timer?

    func scheduleRepeating(
        every interval: TimeInterval,
        _ check: @escaping @MainActor () -> Void
    ) {
        cancelRepeating()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            _ in
            Task { @MainActor in check() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelRepeating() {
        timer?.invalidate()
        timer = nil
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}

/// Delegate protocol that provides PlaybackRecoveryService access to the
/// audio engine state it needs without creating a direct dependency.
@MainActor
protocol PlaybackRecoveryDelegate: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var currentTrackID: String? { get }
    var streamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?))? { get }
    func resumePlayer()
    func next()
    func performRecoveryLoadAndPlay(song: Song)
    func updateRetryState(song: Song, streamURL: String, contentLength: Int64?)
}

/// Handles playback stall detection and automatic retry/recovery.
/// Extracted from AudioEngine to isolate failure-recovery concerns.
@MainActor
@Observable
final class PlaybackRecoveryService {
    // MARK: - State

    private(set) var hasAttemptedRetry: Bool = false
    private var lastObservedTime: TimeInterval = 0
    private var lastTimeChangeInstant: TimeInterval = 0
    private var isWaitingForItem = false
    private var retryTask: Task<Void, Never>?

    // MARK: - Dependencies

    weak var delegate: PlaybackRecoveryDelegate?
    private let clock: any PlaybackRecoveryClock
    private let scheduler: any PlaybackRecoveryScheduling
    private let eventSink: @MainActor (PlaybackRecoveryEvent) -> Void

    init(
        clock: (any PlaybackRecoveryClock)? = nil,
        scheduler: (any PlaybackRecoveryScheduling)? = nil,
        eventSink: @escaping @MainActor (PlaybackRecoveryEvent) -> Void = { _ in }
    ) {
        self.clock = clock ?? SystemPlaybackRecoveryClock()
        self.scheduler = scheduler ?? SystemPlaybackRecoveryScheduler()
        self.eventSink = eventSink
    }

    // MARK: - Lifecycle

    func resetRetry() {
        retryTask?.cancel()
        retryTask = nil
        hasAttemptedRetry = false
    }

    deinit {
        MainActor.assumeIsolated {
            self.scheduler.cancelRepeating()
        }
    }

    // MARK: - Retry

    func retryPlayback(for song: Song) {
        hasAttemptedRetry = true

        guard let delegate, let resolver = delegate.streamURLResolver else {
            delegate?.updateRetryState(song: song, streamURL: "", contentLength: nil)
            Log.audio.error("No stream URL resolver available for retry")
            return
        }

        retryTask?.cancel()
        retryTask = Task { [weak self, weak delegate] in
            guard let self, let delegate else { return }
            defer { if !Task.isCancelled { self.retryTask = nil } }
            Log.audio.info("Retry: Re-resolving stream URL for: \(song.id, privacy: .public)")
            do {
                let result = try await resolver(song.id)
                // Guard: if user skipped to a different song during resolve, discard stale result
                guard !Task.isCancelled, delegate.currentTrackID == song.id else {
                    Log.audio.info("Retry: Song changed during resolve, discarding result for \(song.id, privacy: .public)")
                    return
                }
                Log.audio.info("Retry: stream resolution completed")
                var retrySong = song
                retrySong.streamURL = result.url
                retrySong.streamContentLength = result.contentLength
                delegate.updateRetryState(
                    song: retrySong,
                    streamURL: result.url,
                    contentLength: result.contentLength
                )
                delegate.performRecoveryLoadAndPlay(song: retrySong)
            } catch {
                guard !Task.isCancelled, delegate.currentTrackID == song.id else { return }
                delegate.updateRetryState(song: song, streamURL: "", contentLength: nil)
                Log.audio.error("Retry failed, code=\((error as NSError).code)")
            }
        }
    }

    // MARK: - Stall Detection

    func startLoadingDetection() {
        stopStallDetection()
        isWaitingForItem = true
        lastTimeChangeInstant = clock.now
        scheduler.scheduleRepeating(every: 5) { [weak self] in
            self?.checkForStall()
        }
    }

    func recordLoadingProgress() {
        guard isWaitingForItem else { return }
        lastTimeChangeInstant = clock.now
    }

    func startStallDetection() {
        stopStallDetection()
        lastObservedTime = delegate?.currentTime ?? 0
        lastTimeChangeInstant = clock.now
        scheduler.scheduleRepeating(every: 5) { [weak self] in
            self?.checkForStall()
        }
    }

    func stopStallDetection() {
        scheduler.cancelRepeating()
        isWaitingForItem = false
        retryTask?.cancel()
        retryTask = nil
    }

    private func checkForStall() {
        guard let delegate else { return }
        let currentTime = delegate.currentTime

        guard delegate.isPlaying else {
            lastObservedTime = currentTime
            lastTimeChangeInstant = clock.now
            return
        }

        // At EOF (partial file ended) — not a network stall, skip recovery.
        if isWaitingForItem {
            // Native download requests allow 60 seconds. Give resolution and
            // each segment more time, while bounding a dependency that never returns.
            guard clock.now - lastTimeChangeInstant > 90,
                  let trackID = delegate.currentTrackID else { return }
            stopStallDetection()
            eventSink(.loadingTimedOut(trackID: trackID))
            return
        }

        let dur = delegate.duration
        if dur > 0, currentTime >= dur - 1.0 { return }

        if abs(currentTime - lastObservedTime) < 0.1 {
            if clock.now - lastTimeChangeInstant > 10 {
                Log.audio.warning(
                    "Stall detected: currentTime stuck at \(currentTime) for 10+ seconds"
                )
                handleStall()
            }
        } else {
            lastObservedTime = currentTime
            lastTimeChangeInstant = clock.now
        }
    }

    private func handleStall() {
        guard let delegate, let trackID = delegate.currentTrackID else { return }
        lastTimeChangeInstant = clock.now
        eventSink(
            .stallDetected(trackID: trackID, position: delegate.currentTime)
        )
    }
}
