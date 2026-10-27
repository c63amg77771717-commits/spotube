import AVFoundation
import Foundation
import XCTest
@testable import LovelyMusic

/// Pause, then a dead stream, must play again at the same position without Retry.
@MainActor
final class Build47ResumeTests: XCTestCase {
    func testYouTubeExpireParameterIsHonoredWithLeeway() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = URL(string: "https://rr.googlevideo.com/videoplayback?expire=1700000120&id=a")!
        let soon = URL(string: "https://rr.googlevideo.com/videoplayback?id=a&expire=1700000010")!
        let dead = URL(string: "https://rr.googlevideo.com/videoplayback?expire=1&sig=abc")!
        let unsigned = URL(string: "https://progressive-cdn.example.test/videoplayback?id=build47")!
        XCTAssertFalse(YouTubeStreamExpiry.isExpired(fresh, now: now))
        XCTAssertTrue(YouTubeStreamExpiry.isExpired(soon, now: now))
        XCTAssertTrue(YouTubeStreamExpiry.isExpired(dead, now: now))
        XCTAssertFalse(YouTubeStreamExpiry.isExpired(unsigned, now: now))
    }

    func testPauseThenDeadStreamResumesAtTheSamePositionWithoutRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(
            Data(contentsOf: generated.url), totalSeconds: 20,
            cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        let fresh = "https://progressive-cdn.example.test/videoplayback?id=build47"
        let total = Int64(indexed.data.count)
        ProgressiveCDN.prepare(indexed.data)

        var resolves = 0
        var activations = 0
        let engine = makeEngine(url: fresh, total: total)
        let gate = UpgradeGate()
        defer {
            gate.release()
            engine.stop()
        }
        engine.audioSessionActivator = { activations += 1; return true }
        engine.streamURLResolver = { _ in
            resolves += 1
            return (url: fresh, contentLength: total)
        }
        engine.highQualityUpgrade = { _ in
            await gate.wait()
            return nil
        }

        var song = Song(id: "BUILD47", title: "Resume fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        song.streamURL = fresh
        song.streamContentLength = total
        engine.play(song: song)
        let startedAt = try await waitUntil(engine, advancesPast: 1.0, limit: 12)
        XCTAssertGreaterThan(startedAt, 0)

        engine.handleRemotePause()
        let pausedAt = engine.currentTime
        XCTAssertGreaterThan(pausedAt, 1)
        let activationsBeforeResume = activations
        let generation = engine.playbackSelectionGeneration
        let healthyStarted = Date()
        engine.handleRemotePlay()
        let healthy = try await waitUntil(engine, advancesPast: pausedAt + 0.12, limit: 4)
        print(String(format: "RESUME-LATENCY healthy=%.3f position=%.3f", healthy, engine.currentTime))
        XCTAssertEqual(engine.playbackSelectionGeneration, generation,
                       "A healthy item must resume without rebuilding")
        XCTAssertGreaterThan(activations, activationsBeforeResume, "Play re-activates the audio session")
        XCTAssertFalse(engine.requiresManualPlaybackRecovery)
        XCTAssertNil(engine.lastError)
        XCTAssertLessThan(Date().timeIntervalSince(healthyStarted), 2)
        _ = healthy

        try await waitUntil(engine, advancesPast: pausedAt + 0.4, limit: 4)
        engine.handleRemotePause()
        let rebuildFrom = engine.currentTime
        XCTAssertGreaterThan(rebuildFrom, 1)
        engine.setLyricTimelineOffsetForResumeProbe(12.5)
        engine.suspendSegmentedProxyForResumeProbe()
        engine.rewriteInstalledStreamURLForResumeProbe(fresh + "&expire=1")
        let activationsBeforeRebuild = activations
        let resolvesBeforeForeground = resolves
        engine.applicationDidBecomeActive()
        XCTAssertFalse(engine.isPlaying, "Foreground keeps a manual pause")
        XCTAssertFalse(engine.hasInstalledPlaybackItem, "A dead item is dropped before the user presses play")
        XCTAssertNil(engine.currentTrack?.streamURL)
        XCTAssertEqual(engine.currentTime, rebuildFrom, accuracy: 0.75)
        XCTAssertFalse(engine.requiresManualPlaybackRecovery)
        XCTAssertEqual(resolves, resolvesBeforeForeground, "Foreground must not start a resolve while the user is paused")
        let parked = engine.currentTime

        let resolvesBeforeRebuild = resolves
        let rebuildStarted = Date()
        engine.handleRemotePlay()
        let rebuild = try await waitUntil(engine, advancesPast: parked + 0.12, limit: 8)
        print(String(format: "RESUME-LATENCY rebuild=%.3f position=%.3f", rebuild, engine.currentTime))
        XCTAssertLessThan(rebuild, 6, "Recovery must beat the Retry timeout")
        XCTAssertGreaterThan(engine.currentTime, parked - 1.0)
        XCTAssertEqual(engine.activeAudioCodec, "aac")
        XCTAssertEqual(engine.lyricTimelineOffset, 0, accuracy: 0.000_1,
                       "The rebuilt AAC source re-applies its own timeline offset")
        XCTAssertGreaterThan(resolves, resolvesBeforeRebuild)
        XCTAssertGreaterThan(activations, activationsBeforeRebuild)
        XCTAssertFalse(engine.requiresManualPlaybackRecovery)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertLessThan(Date().timeIntervalSince(rebuildStarted), 6)

        try await waitUntil(engine, advancesPast: engine.currentTime + 0.05, limit: 4)
        engine.handleRemotePause()
        let failedFrom = engine.currentTime
        engine.installFailedItemForResumeProbe()
        var failed = false
        for _ in 0..<150 {
            if engine.installedPlaybackItemFailed { failed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(failed, "The probe item must reach .failed")
        XCTAssertFalse(engine.isPlaying, "A failed item must not start playback while paused")
        let failedPinned = engine.currentTime
        XCTAssertEqual(failedPinned, failedFrom, accuracy: 0.75)
        let failedStarted = Date()
        engine.handleRemotePlay()
        let failedResume = try await waitUntil(engine, advancesPast: failedPinned + 0.12, limit: 8)
        print(String(format: "RESUME-LATENCY failed-item=%.3f position=%.3f", failedResume, engine.currentTime))
        XCTAssertLessThan(failedResume, 6)
        XCTAssertGreaterThan(engine.currentTime, failedPinned - 1.0)
        XCTAssertFalse(engine.requiresManualPlaybackRecovery)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.activeAudioCodec, "aac")
        XCTAssertLessThan(Date().timeIntervalSince(failedStarted), 6)
    }

    private func waitUntil(_ engine: AudioEngine, advancesPast target: TimeInterval, limit: TimeInterval) async throws -> TimeInterval {
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            if engine.currentTime > target, engine.isPlaying, engine.lastError == nil,
               engine.requiresManualPlaybackRecovery == false {
                return Date().timeIntervalSince(started)
            }
            if engine.requiresManualPlaybackRecovery || engine.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Did not advance past \(target) (time=\(engine.currentTime), error=\(engine.lastError ?? "nil"), retry=\(engine.requiresManualPlaybackRecovery))")
        throw NSError(domain: "Build47Resume", code: 1)
    }

    /// Blocks Opus preparation without a throwing sleep, so cancelling the
    /// upgrade cannot fail the test.
    private final class UpgradeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }
        func release() {
            lock.lock()
            let pending = continuations
            continuations.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private func makeEngine(url: String, total: Int64) -> AudioEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveCDN.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        engine.authCookieProvider = { nil }
        engine.streamURLResolver = { _ in (url: url, contentLength: total) }
        return engine
    }
}
