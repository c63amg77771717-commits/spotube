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
        let saved = PlaybackStatePersistence.PersistedPlaybackState(
            queue: [selected], autoplayQueue: [autoplay], currentIndex: 0, currentTime: 47,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date(),
            currentSong: autoplay, isPlayingFromAutoplay: true)
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "persisted_playback_state")
        let restored = try XCTUnwrap(PlaybackStatePersistence().restore())
        XCTAssertNil(restored.queue.first?.streamURL)
        XCTAssertNil(restored.queue.first?.streamContentLength)
        XCTAssertNil(restored.autoplayQueue.first?.streamURL)
        XCTAssertNil(restored.autoplayQueue.first?.streamContentLength)
        XCTAssertNil(restored.currentSong?.streamURL)
        XCTAssertNil(restored.currentSong?.streamContentLength)
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
        XCTAssertEqual(engine.currentTime, 12, accuracy: 0.001)
        XCTAssertFalse(engine.isPlaying, "Automatic recovery must retain a pause received during resolution")
    }

    func testPauseDuringInterruptionCancelsAutomaticResumeIntent() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        postInterruption(.began)
        await Task.yield()
        engine.handleRemotePause()
        postInterruption(.ended, options: .shouldResume)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
    }

    func testInterruptionResumesPreviouslyActivePlaybackWhenAllowed() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        postInterruption(.began)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        postInterruption(.ended, options: .shouldResume)
        await Task.yield()
        XCTAssertTrue(engine.isPlaying)
    }

    func testPauseDuringInitialResolutionKeepsTheInstalledAudioPaused() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let file = try fixtureURL()
        let started = expectation(description: "Initial resolver started")
        var release: CheckedContinuation<(url: String, contentLength: Int64?), Error>?
        engine.streamURLResolver = { _ in
            try await withCheckedThrowingContinuation { continuation in
                release = continuation
                started.fulfill()
            }
        }
        engine.play(song: song())
        await fulfillment(of: [started], timeout: 2)
        engine.playPause()
        release?.resume(returning: (file.absoluteString, nil))
        for _ in 0..<100 where engine.localFileURL == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(engine.localFileURL, file)
        XCTAssertFalse(engine.isPlaying)
    }

    func testActualPlaybackReportsHistoryOnceAcrossPauseAndRecovery() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let file = try fixtureURL()
        let selected = song(url: file)
        let started = expectation(description: "Actual AVPlayer playback observed")
        var reported: [String] = []
        engine.onPlaybackStarted = { song in
            reported.append(song.id)
            if reported.count == 1 { started.fulfill() }
        }
        engine.streamURLResolver = { _ in (file.absoluteString, nil) }
        engine.play(song: selected)
        await fulfillment(of: [started], timeout: 5)
        engine.handleRemotePause()
        engine.handleRemotePlay()
        engine.receivePlaybackRecoveryEvent(.stallDetected(trackID: selected.id, position: 12))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reported, ["reliable001"])
    }

    func testFailedResolutionDoesNotReportPlaybackHistory() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        var reported: [Song] = []
        engine.onPlaybackStarted = { reported.append($0) }
        engine.streamURLResolver = { _ in throw InnerTubeError.timeout }
        engine.play(song: song())
        for _ in 0..<100 where engine.lastError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(engine.lastError)
        XCTAssertTrue(reported.isEmpty)
    }

    func testBuild9UpgradeEnablesRestorationOnceAndRespectsLaterOptOut() throws {
        let suite = "PlaybackReliability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "persistentQueue")
        PlaybackStatePersistence.registerBuild9Defaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: "persistentQueue"))
        defaults.set(false, forKey: "persistentQueue")
        PlaybackStatePersistence.registerBuild9Defaults(defaults)
        XCTAssertFalse(defaults.bool(forKey: "persistentQueue"))
    }

    func testEverySaveImmediatelyRestoresTheLatestSnapshot() throws {
        UserDefaults.standard.set(true, forKey: "persistentQueue")
        let store = PlaybackStatePersistence()
        for position in 1...10 {
            store.save(queue: [song()], autoplayQueue: [], currentIndex: 0,
                       currentTime: Double(position), isPlaying: false,
                       shuffleEnabled: false, repeatMode: "off")
            XCTAssertEqual(try XCTUnwrap(store.restore()).currentTime, Double(position))
        }
        store.clear()
        XCTAssertNil(store.restore())
    }

    func testActiveAutoplaySelectionAndRemainingQueueSurviveManualRestore() async throws {
        UserDefaults.standard.set(true, forKey: "persistentQueue")
        let store = PlaybackStatePersistence()
        let user = song()
        let active = song(id: "reliable003")
        let remaining = song(id: "reliable004")
        let original = AudioEngine()
        defer { original.stop() }
        original.playbackStatePersistence = store
        original.restorePlaybackState(.init(queue: [user], autoplayQueue: [remaining], currentIndex: 0,
            currentTime: 47, wasPlaying: true, shuffleEnabled: false, repeatMode: "off", savedAt: Date(),
            currentSong: active, isPlayingFromAutoplay: true))
        original.savePlaybackState()
        let saved = try XCTUnwrap(store.restore())
        let restored = AudioEngine()
        defer { restored.stop() }
        restored.restorePlaybackState(saved)
        XCTAssertEqual(restored.currentTrack?.id, "reliable003")
        XCTAssertEqual(restored.currentTime, 47, accuracy: 0.001)
        XCTAssertTrue(restored.isPlayingFromAutoplay)
        XCTAssertFalse(restored.isPlaying)
        let invoked = expectation(description: "Manual play resolves the restored autoplay track")
        restored.streamURLResolver = { id in
            XCTAssertEqual(id, "reliable003")
            invoked.fulfill()
            throw InnerTubeError.timeout
        }
        restored.playPause()
        await fulfillment(of: [invoked], timeout: 2)
        XCTAssertEqual(restored.queue.map(\.id), ["reliable001"])
        XCTAssertEqual(restored.autoplayQueue.map(\.id), ["reliable004"])
        XCTAssertTrue(restored.isPlayingFromAutoplay)
    }

    func testOldSavedStateWithoutAutoplaySelectionFieldsStillRestoresUserSong() throws {
        let encoded = try JSONEncoder().encode(state(queue: [song()], position: 47))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "currentSong")
        json.removeValue(forKey: "isPlayingFromAutoplay")
        let old = try JSONDecoder().decode(PlaybackStatePersistence.PersistedPlaybackState.self,
                                         from: JSONSerialization.data(withJSONObject: json))
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.restorePlaybackState(old)
        XCTAssertEqual(engine.currentTrack?.id, "reliable001")
        XCTAssertEqual(engine.currentTime, 47, accuracy: 0.001)
        XCTAssertFalse(engine.isPlayingFromAutoplay)
        XCTAssertFalse(engine.isPlaying)
    }

    func testSavedCurrentSongTakesPrecedenceOverQueueIndex() {
        let engine = AudioEngine()
        defer { engine.stop() }
        let active = song(id: "reliable002")
        engine.restorePlaybackState(.init(queue: [song()], autoplayQueue: [], currentIndex: 0,
            currentTime: 47, wasPlaying: true, shuffleEnabled: false, repeatMode: "off", savedAt: Date(),
            currentSong: active, isPlayingFromAutoplay: false))
        XCTAssertEqual(engine.currentTrack?.id, active.id)
        XCTAssertEqual(engine.currentTime, 47, accuracy: 0.001)
        XCTAssertFalse(engine.isPlayingFromAutoplay)
        XCTAssertFalse(engine.isPlaying)
    }

    func testEngineBoundsHungInitialResolutionAndRetriesOnlyOnce() async throws {
        let clock = ReliabilityClock()
        let scheduler = ReliabilityScheduler()
        let engine = AudioEngine(recoveryClock: clock, recoveryScheduler: scheduler)
        var pending: [CheckedContinuation<(url: String, contentLength: Int64?), Error>] = []
        defer {
            engine.stop()
            for continuation in pending { continuation.resume(throwing: CancellationError()) }
        }
        let first = expectation(description: "Initial resolver starts")
        let retry = expectation(description: "Bounded resolver retry starts")
        let manual = expectation(description: "Manual play starts a new attempt")
        var calls = 0
        engine.streamURLResolver = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                if calls == 1 { first.fulfill() }
                else if calls == 2 { retry.fulfill() }
                else if calls == 3 { manual.fulfill() }
            }
        }
        engine.restorePlaybackState(state(queue: [song()], position: 47))
        engine.playPause()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertNotNil(scheduler.check, "Engine must monitor the interval before item installation")
        clock.now = 11
        scheduler.check?()
        clock.now = 89
        scheduler.check?()
        XCTAssertEqual(calls, 1, "Normal loading must not use the 10-second playback stall deadline")
        clock.now = 91
        scheduler.check?()
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertEqual(engine.currentTime, 47, accuracy: 0.001)
        clock.now = 182
        scheduler.check?()
        await Task.yield()
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
        XCTAssertNotNil(engine.lastError)
        XCTAssertNil(scheduler.check)
        engine.handleRemotePlay()
        await fulfillment(of: [manual], timeout: 2)
        XCTAssertEqual(calls, 3)
    }

    func testPausedInitialResolutionDoesNotConsumeLoadingRetryBudget() async throws {
        let clock = ReliabilityClock()
        let scheduler = ReliabilityScheduler()
        let engine = AudioEngine(recoveryClock: clock, recoveryScheduler: scheduler)
        var pending: [CheckedContinuation<(url: String, contentLength: Int64?), Error>] = []
        defer {
            engine.stop()
            for continuation in pending { continuation.resume(throwing: CancellationError()) }
        }
        let first = expectation(description: "Resolver starts before pause")
        let retry = expectation(description: "Resolver retry starts after resumed deadline")
        var calls = 0
        engine.streamURLResolver = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                if calls == 1 { first.fulfill() }
                else if calls == 2 { retry.fulfill() }
            }
        }
        engine.play(song: song())
        await fulfillment(of: [first], timeout: 2)
        engine.handleRemotePause()
        clock.now = 500
        scheduler.check?()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(engine.lastError)
        engine.handleRemotePlay()
        clock.now = 589
        scheduler.check?()
        XCTAssertEqual(calls, 1)
        clock.now = 591
        scheduler.check?()
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertEqual(calls, 2)
    }

    func testDiagnosticPlaybackTransitionsRetainOnlyFiniteTypedState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(phase: .remotePause, videoID: "SECRET_COOKIE", positionSeconds: .nan,
                           isPlaying: false, isBuffering: true))
        store.record(.init(phase: .engineStall, videoID: "reliable001", positionSeconds: 47,
                           isPlaying: true, isBuffering: true))
        store.record(.init(phase: .engineRecovery, positionSeconds: -.infinity))
        let restored = PlaybackDiagnostics(fileURL: file)
        XCTAssertNil(restored.events[0].videoID)
        XCTAssertNil(restored.events[0].positionSeconds)
        XCTAssertEqual(restored.events[1].phase, .engineStall)
        XCTAssertEqual(restored.events[1].positionSeconds, 47)
        XCTAssertEqual(restored.events[1].isPlaying, true)
        XCTAssertEqual(restored.events[1].isBuffering, true)
        XCTAssertNil(restored.events[2].positionSeconds)
        let json = String(decoding: try restored.reportData(), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET_COOKIE"))
        XCTAssertFalse(json.contains("https://"))
    }

    func testLoadingDeadlineTracksProgressInsteadOfTotalDownloadDuration() {
        let clock = ReliabilityClock()
        let scheduler = ReliabilityScheduler()
        let delegate = ReliabilityRecoveryDelegate()
        var events: [PlaybackRecoveryEvent] = []
        let service = PlaybackRecoveryService(clock: clock, scheduler: scheduler, eventSink: { events.append($0) })
        service.delegate = delegate
        service.startLoadingDetection()
        for time in [60.0, 120.0, 180.0, 240.0] {
            clock.now = time
            scheduler.check?()
            service.recordLoadingProgress()
        }
        clock.now = 329
        scheduler.check?()
        XCTAssertTrue(events.isEmpty, "A progressing download may take longer than 90 seconds in total")
        clock.now = 331
        scheduler.check?()
        XCTAssertEqual(events, [.loadingTimedOut(trackID: "reliable001")])
        XCTAssertNil(scheduler.check)
        XCTAssertEqual(delegate.nextCount, 0)
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

    func testMediaServicesResetAllowsSameSelectionToResumeWithoutSelectingAgain() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let selected = song(url: try fixtureURL())
        let next = song(id: "reliable002")
        engine.play(song: selected, fromQueue: [selected, next], seekTo: 17)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                       object: AVAudioSession.sharedInstance())
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentTrack?.id, selected.id)
        XCTAssertEqual(engine.queue.map(\.id), [selected.id, next.id])
        XCTAssertEqual(engine.currentTime, 17, accuracy: 0.001)
        engine.handleRemotePlay()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.localFileURL, URL(string: selected.streamURL!))
        XCTAssertEqual(engine.currentTime, 17, accuracy: 0.001)
    }

    func testExplicitPlayCanRecoverMissingInterruptionEndAfterSuspension() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.play(song: song(url: try fixtureURL()))
        postInterruption(.began)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        engine.applicationDidBecomeActive()
        XCTAssertFalse(engine.isPlaying, "Foreground alone must not override a system interruption")
        engine.handleRemotePlay()
        XCTAssertTrue(engine.isPlaying, "Successful audio activation on explicit play clears a stale interruption")
        engine.handleRemotePause()
        engine.applicationDidBecomeActive()
        XCTAssertFalse(engine.isPlaying, "Returning to foreground must preserve a manual pause")
    }

    func testMissingLocalArtifactResolvesAgainAndKeepsPositionAndQueue() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let selected = song(url: missing)
        let next = song(id: "reliable002")
        engine.restorePlaybackState(state(queue: [selected, next], position: 31))
        let invoked = expectation(description: "A disappeared temp file re-enters the resolver")
        engine.streamURLResolver = { id in
            XCTAssertEqual(id, selected.id)
            invoked.fulfill()
            throw InnerTubeError.timeout
        }
        engine.handleRemotePlay()
        await fulfillment(of: [invoked], timeout: 2)
        XCTAssertEqual(engine.currentTrack?.id, selected.id)
        XCTAssertEqual(engine.currentTime, 31, accuracy: 0.001)
        XCTAssertEqual(engine.queue.map(\.id), [selected.id, next.id])
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
