import AVFoundation
import XCTest
@testable import LovelyMusic

@MainActor
final class InterruptionRecoveryEpochTests: XCTestCase {
    private var defaultsBackup: [String: Any] = [:]
    private let keys = ["persistentQueue", "persisted_playback_state", "playbackShuffleEnabled", "playbackRepeatMode", "crossfade_duration"]

    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { defaultsBackup[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(false, forKey: "playbackShuffleEnabled")
        UserDefaults.standard.set("off", forKey: "playbackRepeatMode")
        UserDefaults.standard.set(0, forKey: "crossfade_duration")
    }

    override func tearDown() {
        for key in keys {
            if let value = defaultsBackup[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaultsBackup.removeAll()
        super.tearDown()
    }
    func testTwoIndependentInterruptionsEachAllowOneRecoveryAndRetainPosition() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        let replacement = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_evening_calm", withExtension: "m4a"))
        var calls = 0
        engine.streamURLResolver = { _ in calls += 1; return (replacement.absoluteString, nil) }
        let song = track(url: fixture)
        engine.play(song: song, fromQueue: [song])
        for (index, position) in [12.0, 24.0].enumerated() {
            interrupt(.began)
            await Task.yield()
            interrupt(.ended, resume: true)
            await Task.yield()
            engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: position))
            for _ in 0..<100 where calls < index + 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            for _ in 0..<100 where engine.currentTime < position { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(calls, index + 1)
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.01)
            engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: position))
            await Task.yield()
            XCTAssertEqual(calls, index + 1, "A repeated watchdog event must not reopen the budget")
        }
        XCTAssertEqual(engine.queue.map(\.id), [song.id])
    }

    func testDuplicateEndAndRemotePlayDoNotCreateUnlimitedRecovery() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var calls = 0
        engine.streamURLResolver = { _ in calls += 1; return (fixture.absoluteString, nil) }
        let song = track(url: fixture)
        engine.play(song: song)
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: 12))
        for _ in 0..<100 where calls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        for _ in 0..<100 where engine.currentTime < 12 { try await Task.sleep(nanoseconds: 10_000_000) }
        interrupt(.ended, resume: true)
        await Task.yield()
        engine.handleRemotePlay()
        engine.handleRemotePlay()
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: 12))
        await Task.yield()
        XCTAssertEqual(calls, 1)
    }

    func testPauseAndActiveInterruptionRejectQueuedStallEvents() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var calls = 0
        engine.streamURLResolver = { _ in calls += 1; return (fixture.absoluteString, nil) }
        let song = track(url: fixture)
        engine.play(song: song)
        interrupt(.began)
        await Task.yield()
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: 12))
        engine.handleRemotePause()
        interrupt(.ended, resume: true)
        await Task.yield()
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: song.id, position: 12))
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(calls, 0)
    }

    private func track(url: URL) -> Song {
        var song = Song(id: "epoch000001", title: "Interruption fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
        song.streamURL = url.absoluteString
        return song
    }

    private func interrupt(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                       AVAudioSessionInterruptionOptionKey: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
    }
}
