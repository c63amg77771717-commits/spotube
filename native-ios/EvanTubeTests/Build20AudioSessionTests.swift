import AVFoundation
import XCTest
@testable import LovelyMusic

@MainActor
final class Build20AudioSessionTests: XCTestCase {
    private let keys = ["persistentQueue", "persisted_playback_state", "playbackShuffleEnabled", "playbackRepeatMode",
                        "crossfade_duration", "audioNormalization", "skipSilence", "playbackSpeed", "equalizerEnabled",
                        "equalizerPreset", "equalizerCustomBands"]
    private var backup: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { backup[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(false, forKey: "playbackShuffleEnabled")
        UserDefaults.standard.set("off", forKey: "playbackRepeatMode")
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    override func tearDown() {
        try? AVAudioSession.sharedInstance().setActive(false)
        for key in keys {
            if let value = backup[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        backup.removeAll()
        super.tearDown()
    }

    func testPlaybackCategoryIsEligibleForSystemNowPlaying() {
        AudioSessionManager.setCategory()
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        XCTAssertFalse(session.categoryOptions.contains(.interruptSpokenAudioAndMixWithOthers))
        let event = PlaybackDiagnostics.shared.events.last { $0.phase == .audioSessionConfigured }
        XCTAssertEqual(event?.audioMixingEnabled, false)
    }

    func testLazyActivationReportsActualSuccessAndPreservesNowPlayingPolicy() {
        AudioSessionManager.setCategory()
        XCTAssertTrue(AudioSessionManager.activate())
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        let event = PlaybackDiagnostics.shared.events.last { $0.phase == .audioSessionActivated }
        XCTAssertEqual(event?.audioActivationSucceeded, true)
        XCTAssertEqual(event?.audioMixingEnabled, false)
    }

    func testFiveIndependentGenuineInterruptionsRetainQueueSpeedAndProcessingSettings() async throws {
        UserDefaults.standard.set(2.0, forKey: "crossfade_duration")
        UserDefaults.standard.set(true, forKey: "audioNormalization")
        UserDefaults.standard.set(true, forKey: "equalizerEnabled")
        let engine = AudioEngine()
        defer { engine.stop() }
        let eq = EqualizerManager()
        eq.customBands = [1, 0, -1, 0, 2, 0, -2, 0, 1, 0]
        engine.equalizerManager = eq
        engine.playbackSpeed = 1.25
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var song = Song(id: "audio000001", title: "Audio fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        song.streamURL = fixture.absoluteString
        var resolutions = 0
        engine.streamURLResolver = { _ in resolutions += 1; return (fixture.absoluteString, nil) }
        engine.play(song: song)
        for _ in 0..<100 where !engine.isPlaying { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(engine.isPlaying)
        for _ in 0..<5 {
            interrupt(.began)
            XCTAssertFalse(engine.isPlaying)
            interrupt(.ended, shouldResume: true)
            await Task.yield()
            XCTAssertTrue(engine.isPlaying)
            XCTAssertEqual(engine.currentTrack?.id, song.id)
            XCTAssertEqual(engine.queue.map(\.id), [song.id])
            XCTAssertEqual(engine.playbackSpeed, 1.25)
            XCTAssertTrue(engine.normalizationEnabled)
            XCTAssertTrue(eq.isEnabled)
            XCTAssertEqual(eq.customBands, [1, 0, -1, 0, 2, 0, -2, 0, 1, 0])
            XCTAssertEqual(UserDefaults.standard.double(forKey: "crossfade_duration"), 2)
        }
        XCTAssertEqual(resolutions, 0, "System interruptions must not re-resolve an already loaded local source")
    }

    func testManualPauseDuringGenuineInterruptionPreventsAutomaticResume() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var song = Song(id: "audio000002", title: "Pause fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        song.streamURL = fixture.absoluteString
        engine.play(song: song)
        interrupt(.began)
        engine.handleRemotePause()
        interrupt(.ended, shouldResume: true)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentTrack?.id, song.id)
        XCTAssertEqual(engine.queue.map(\.id), [song.id])
        let event = PlaybackDiagnostics.shared.events.last { $0.phase == .interruptionEnded }
        XCTAssertEqual(event?.manualPause, true)
        XCTAssertEqual(event?.interruptionShouldResume, false)
    }

    func testInterruptionWithoutShouldResumeAndDuplicateEndDoNotResume() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var song = Song(id: "audio000003", title: "No-resume fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        song.streamURL = fixture.absoluteString
        engine.play(song: song)
        interrupt(.began)
        interrupt(.ended)
        interrupt(.ended, shouldResume: true)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
    }

    func testNewAudioDiagnosticsRemainSanitizedAndDecodeOldEvents() throws {
        let event = PlaybackDiagnostics.Event(phase: .interruptionEnded, videoID: "private invalid URL",
            audioMixingEnabled: true, playbackRate: .nan, manualPause: true, routeOutputCount: -1,
            interruptionShouldResume: false)
        XCTAssertNil(event.sanitized.videoID)
        XCTAssertNil(event.sanitized.playbackRate)
        XCTAssertNil(event.sanitized.routeOutputCount)
        XCTAssertEqual(event.sanitized.manualPause, true)
        let old = Data("{\"timestamp\":\"2026-10-05T00:00:00Z\",\"phase\":\"interruptionBegan\"}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PlaybackDiagnostics.Event.self, from: old)
        XCTAssertNil(decoded.audioMixingEnabled)
        XCTAssertEqual(decoded.phase, .interruptionBegan)
    }

    func testFailedResumeActivationKeepsPlayerPausedAndExplicitRetryCanRecover() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        var song = Song(id: "audio000004", title: "Activation fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
        song.streamURL = fixture.absoluteString
        engine.play(song: song)
        try await Task.sleep(nanoseconds: 10_000_000)
        for _ in 0..<200 where !engine.isPlaying || engine.isBuffering { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
        engine.handleRemotePause()
        var attempts = 0
        engine.audioSessionActivator = { attempts += 1; return false }
        engine.handleRemotePlay()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNotNil(engine.lastError)
        XCTAssertEqual(engine.currentTrack?.id, song.id)
        XCTAssertEqual(engine.queue.map(\.id), [song.id])
        engine.audioSessionActivator = { AudioSessionManager.activate() }
        engine.handleRemotePlay()
        XCTAssertTrue(engine.isPlaying)
    }

    private func interrupt(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                       AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
    }
}
