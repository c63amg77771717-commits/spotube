import AVFoundation
import Foundation
import XCTest
@testable import LovelyMusic

/// Time-to-first-audio on the Build45 progressive AAC path, with Opus work
/// still in flight, and with a forced Opus failure.
@MainActor
final class Build46StartTimeTests: XCTestCase {
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var started = false
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                started = true
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    func testOpusPreparationDoesNotDelayFirstAudioAndFailureStaysOnAAC() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(Data(contentsOf: generated.url), totalSeconds: 20,
                                                   cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        let url = "https://progressive-cdn.example.test/videoplayback?id=build46"
        let total = Int64(indexed.data.count)

        ProgressiveCDN.prepare(indexed.data)
        let baseline = try await play(url: url, total: total, upgrade: nil)
        print(String(format: "START-TIME aac=%.3f", baseline))

        ProgressiveCDN.prepare(indexed.data)
        let hold = Hold()
        let pendingStarted = Date()
        let pendingEngine = makeEngine(url: url, total: total)
        defer { pendingEngine.stop() }
        pendingEngine.highQualityUpgrade = { _ in
            await hold.wait()
            return nil
        }
        var song = Song(id: "BUILD46AAC", title: "Progressive start fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        song.streamURL = url
        song.streamContentLength = total
        pendingEngine.play(song: song)
        var pending: TimeInterval?
        var sawUpgrade = false
        for _ in 0..<750 {
            if pending == nil, pendingEngine.currentTime > 0 {
                pending = Date().timeIntervalSince(pendingStarted)
            }
            if hold.started { sawUpgrade = true }
            if pending != nil && sawUpgrade { break }
            if pendingEngine.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pendingTime = try XCTUnwrap(pending, pendingEngine.lastError ?? "AAC never started")
        XCTAssertTrue(sawUpgrade, "Opus preparation must be in flight when audio starts")
        XCTAssertEqual(pendingEngine.activeAudioCodec, "aac")
        XCTAssertEqual(pendingEngine.lyricTimelineOffset, 0, accuracy: 0.000_1)
        hold.release()
        print(String(format: "START-TIME aac-while-opus-prepares=%.3f delta-vs-aac=%.3f", pendingTime, pendingTime - baseline))
        XCTAssertLessThan(pendingTime - baseline, 4, "waiting on Opus moved time-to-first-audio")

        ProgressiveCDN.prepare(indexed.data)
        let failed = makeEngine(url: url, total: total)
        defer { failed.stop() }
        let missing = directory.appendingPathComponent("missing-opus.caf")
        failed.highQualityUpgrade = { _ in
            PreparedAudioUpgrade(fileURL: missing, timelineOffset: 1, codec: "opus")
        }
        failed.play(song: song)
        for _ in 0..<750 {
            if failed.currentTime >= 2 || failed.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(failed.lastError)
        XCTAssertGreaterThanOrEqual(failed.currentTime, 2)
        XCTAssertEqual(failed.activeAudioCodec, "aac", "a failed Opus file must leave AAC playing")
        print(String(format: "START-TIME opus-failed-aac-still-playing=%.3f", failed.currentTime))
    }

    func testOpusSwitchKeepsPlayingFromTheSamePosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(Data(contentsOf: generated.url), totalSeconds: 20,
                                                   cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        ProgressiveCDN.prepare(indexed.data)
        let url = "https://progressive-cdn.example.test/videoplayback?id=build46-switch"
        let engine = makeEngine(url: url, total: Int64(indexed.data.count))
        defer { engine.stop() }
        let tone = try playableTone(in: directory)
        let box = PositionBox()
        engine.highQualityUpgrade = { [weak engine] _ in
            for _ in 0..<200 where (engine?.currentTime ?? 0) < 0.4 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            box.atSwitch = engine?.currentTime ?? 0
            return PreparedAudioUpgrade(fileURL: tone, timelineOffset: 312.0 / 48_000, codec: "opus")
        }
        var song = Song(id: "BUILD46SW", title: "Progressive start fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        song.streamURL = url
        song.streamContentLength = Int64(indexed.data.count)
        engine.play(song: song)
        for _ in 0..<750 {
            if engine.activeAudioCodec == "opus" || engine.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.activeAudioCodec, "opus")
        XCTAssertEqual(engine.lyricTimelineOffset, 312.0 / 48_000, accuracy: 0.000_001)
        let switchedAt = box.atSwitch
        XCTAssertGreaterThan(switchedAt, 0)
        for _ in 0..<750 where engine.currentTime < switchedAt + 0.4 && engine.lastError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(engine.lastError)
        XCTAssertGreaterThan(engine.currentTime, switchedAt, "playback continues after the AAC to Opus switch")
        print(String(format: "START-TIME opus-switch-at=%.3f continued-to=%.3f", switchedAt, engine.currentTime))
    }

    private func play(url: String, total: Int64, upgrade: ((String) async -> PreparedAudioUpgrade?)?) async throws -> TimeInterval {
        let engine = makeEngine(url: url, total: total)
        defer { engine.stop() }
        engine.highQualityUpgrade = upgrade
        var song = Song(id: "BUILD46BASE", title: "Progressive start fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        song.streamURL = url
        song.streamContentLength = total
        let started = Date()
        engine.play(song: song)
        for _ in 0..<750 {
            if engine.currentTime > 0 { return Date().timeIntervalSince(started) }
            if engine.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(engine.lastError ?? "baseline AAC did not start")
        return 99
    }

    /// Linear PCM in CAF. AVPlayer plays this on the simulator; a raw fMP4 does not.
    private func playableTone(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("tone.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw NSError(domain: "Build46", code: 1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 8) else {
            throw NSError(domain: "Build46", code: 2)
        }
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
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

    private final class PositionBox: @unchecked Sendable {
        var atSwitch: TimeInterval = 0
    }
}
