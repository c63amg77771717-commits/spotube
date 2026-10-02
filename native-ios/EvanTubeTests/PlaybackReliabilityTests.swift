import AVFoundation
import XCTest
@testable import LovelyMusic

@MainActor
final class PlaybackReliabilityTests: XCTestCase {
    private var defaultsBackup: [String: Any] = [:]
    private let defaultsKeys = ["persistentQueue", "persisted_playback_state",
                                "playbackShuffleEnabled", "playbackRepeatMode", "crossfade_duration"]

    override func setUp() {
        super.setUp()
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { defaultsBackup[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(false, forKey: "playbackShuffleEnabled")
        UserDefaults.standard.set("off", forKey: "playbackRepeatMode")
        UserDefaults.standard.set(0, forKey: "crossfade_duration")
    }

    override func tearDown() {
        for key in defaultsKeys {
            if let value = defaultsBackup[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaultsBackup.removeAll()
        super.tearDown()
    }

    func testRestoredSelectionRetainsPositionWithoutAutoplay() {
        let engine = AudioEngine()
        defer { engine.stop() }
        let selected = song()
        engine.restorePlaybackState(state(queue: [selected], position: 47))
        XCTAssertEqual(engine.currentTrack?.id, selected.id)
        XCTAssertEqual(engine.currentTime, 47, accuracy: 0.001)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
    }

    func testPressingPlayOnRestoredSelectionStartsResolverAndPreservesQueue() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let selected = song()
        let next = song(id: "reliable002")
        let autoplay = song(id: "reliable003")
        let invoked = expectation(description: "Restored track enters production resolver")
        engine.streamURLResolver = { id in
            XCTAssertEqual(id, selected.id)
            invoked.fulfill()
            throw InnerTubeError.timeout
        }
        engine.restorePlaybackState(state(queue: [selected, next], autoplay: [autoplay], position: 47))
        engine.playPause()
        await fulfillment(of: [invoked], timeout: 2)
        XCTAssertEqual(engine.queue.map(\.id), [selected.id, next.id])
        XCTAssertEqual(engine.autoplayQueue.map(\.id), [autoplay.id])
        XCTAssertEqual(engine.currentTime, 47, accuracy: 0.001)
    }

    func testRestoreDiscardsPersistedSignedStreamURLsInBothQueues() throws {
        UserDefaults.standard.set(true, forKey: "persistentQueue")
        var selected = song()
        selected.streamURL = "https://example.test/audio?expire=1"
        selected.streamContentLength = 1234
        var autoplay = song(id: "reliable003")
        autoplay.streamURL = selected.streamURL
        autoplay.streamContentLength = 1234
        let saved = state(queue: [selected], autoplay: [autoplay], position: 47)
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "persisted_playback_state")
        let restored = try XCTUnwrap(PlaybackStatePersistence().restore())
        XCTAssertNil(restored.queue.first?.streamURL)
        XCTAssertNil(restored.queue.first?.streamContentLength)
        XCTAssertNil(restored.autoplayQueue.first?.streamURL)
        XCTAssertNil(restored.autoplayQueue.first?.streamContentLength)
        XCTAssertEqual(restored.currentTime, 47, accuracy: 0.001)
    }

    func testExplicitRemotePauseIsIdempotent() throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        engine.handleRemotePause()
        engine.handleRemotePause()
        XCTAssertFalse(engine.isPlaying, "A second system pause must not resume playback")
    }

    func testExplicitRemotePlayIsIdempotent() throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        engine.playPause()
        engine.handleRemotePlay()
        engine.handleRemotePlay()
        XCTAssertTrue(engine.isPlaying, "A second system play must not pause playback")
    }

    func testInterruptionResumeHintDoesNotAutoplayPreviouslyPausedTrack() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        engine.playPause()
        postInterruption(.began)
        await Task.yield()
        postInterruption(.ended, options: .shouldResume)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying, "shouldResume is a hint, not new user playback intent")
    }

    func testPauseDuringRecoveryResolutionPreventsDelayedAutoplay() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let selected = song(url: try fixtureURL())
        let freshFile = try fixtureURL(name: "demo_song_evening_calm")
        let started = expectation(description: "Recovery resolver started")
        var release: CheckedContinuation<(url: String, contentLength: Int64?), Error>?
        engine.streamURLResolver = { _ in
            try await withCheckedThrowingContinuation { continuation in
                release = continuation
                started.fulfill()
            }
        }
        engine.play(song: selected)
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: selected.id, position: 12))
        await fulfillment(of: [started], timeout: 2)
        engine.playPause()
        XCTAssertFalse(engine.isPlaying)
        release?.resume(returning: (freshFile.absoluteString, nil))
        for _ in 0..<100 where engine.localFileURL != freshFile {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.localFileURL, freshFile)
        XCTAssertFalse(engine.isPlaying, "Automatic recovery must retain a pause received during resolution")
    }

    func testProlongedBufferingReportsStallWithoutAdvancingQueue() {
        let clock = ReliabilityClock()
        let scheduler = ReliabilityScheduler()
        let delegate = ReliabilityRecoveryDelegate()
        var events: [PlaybackRecoveryEvent] = []
        let service = PlaybackRecoveryService(clock: clock, scheduler: scheduler, eventSink: { events.append($0) })
        service.delegate = delegate
        service.startStallDetection()
        clock.now = 11
        scheduler.check?()
        XCTAssertEqual(events, [.stallDetected(trackID: "reliable001", position: 12)])
        XCTAssertEqual(delegate.nextCount, 0)
        service.stopStallDetection()
    }

    private func song(id: String = "reliable001", url: URL? = nil) -> Song {
        var result = Song(id: id, title: "Reliability fixture", artistName: "Fixture", artistId: nil,
                          albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
        result.streamURL = url?.absoluteString
        return result
    }

    private func state(queue: [Song], autoplay: [Song] = [], position: TimeInterval) -> PlaybackStatePersistence.PersistedPlaybackState {
        .init(queue: queue, autoplayQueue: autoplay, currentIndex: 0, currentTime: position,
              wasPlaying: true, shuffleEnabled: false, repeatMode: "off", savedAt: Date())
    }

    private func fixtureURL(name: String = "demo_song_morning_light") throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "m4a"))
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                AVAudioSessionInterruptionOptionKey: options.rawValue])
    }
}

@MainActor
private final class ReliabilityClock: PlaybackRecoveryClock { var now: TimeInterval = 0 }

@MainActor
private final class ReliabilityScheduler: PlaybackRecoveryScheduling {
    var check: (@MainActor () -> Void)?
    func scheduleRepeating(every interval: TimeInterval, _ check: @escaping @MainActor () -> Void) { self.check = check }
    func cancelRepeating() { check = nil }
    func sleep(for interval: TimeInterval) async throws { }
}

@MainActor
private final class ReliabilityRecoveryDelegate: PlaybackRecoveryDelegate {
    var isPlaying = true
    var isBuffering = true
    var currentTime: TimeInterval = 12
    var duration: TimeInterval = 180
    var currentTrackID: String? = "reliable001"
    var streamURLResolver: ((String) async throws -> (url: String, contentLength: Int64?))?
    var nextCount = 0
    func resumePlayer() { }
    func next() { nextCount += 1 }
    func performRecoveryLoadAndPlay(song: Song) { }
    func updateRetryState(song: Song, streamURL: String, contentLength: Int64?) { }
}
