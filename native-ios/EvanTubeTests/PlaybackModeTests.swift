import XCTest
@testable import LovelyMusic

final class PlaybackModeTests: XCTestCase {
    @MainActor private func withShuffledEngine(_ check: (AudioEngine) -> Void) {
        let defaults = UserDefaults.standard
        let keys = ["persistentQueue", "playbackShuffleEnabled", "playbackRepeatMode"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: "persistentQueue")
        defaults.set(true, forKey: "playbackShuffleEnabled")
        defaults.set("off", forKey: "playbackRepeatMode")
        let engine = AudioEngine()
        defer {
            engine.stop()
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        check(engine)
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Test", artistId: nil,
            albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
    }

    @MainActor func testAutoplayRecoveryDoesNotReplaceAUserQueueSongsStream() {
        withShuffledEngine { engine in
            let original = song("queueSong01")
            var autoplay = song("autoSong001")
            engine.play(song: original, fromQueue: [original])
            engine.setAutoplayQueue([autoplay])
            engine.playNextFromAutoplay()
            autoplay.streamURL = "https://example.com/recovered"
            engine.updateRetryState(song: autoplay, streamURL: autoplay.streamURL!, contentLength: 100)
            XCTAssertEqual(engine.currentTrack?.id, autoplay.id)
            XCTAssertEqual(engine.queue.first?.id, original.id)
            XCTAssertNil(engine.queue.first?.streamURL, "Recovery must not assign another songs stream to this entry")
        }
    }

    @MainActor func testRetryKeepsAutoplayContextAndUsesRemainingSongs() {
        withShuffledEngine { engine in
            let original = song("queueSong01")
            let autoplay = song("autoSong001")
            let remaining = [song("autoSong002"), song("autoSong003")]
            engine.play(song: original, fromQueue: [original])
            engine.setAutoplayQueue([autoplay])
            engine.playNextFromAutoplay()
            engine.setAutoplayQueue(remaining)
            engine.play(song: autoplay)
            XCTAssertTrue(engine.shuffleEnabled)
            XCTAssertTrue(engine.isPlayingFromAutoplay, "Retry must preserve the active queue source")
            engine.next(userInitiated: false)
            XCTAssertTrue(remaining.contains(where: { $0.id == engine.currentTrack?.id }))
        }
    }

    @MainActor func testStartingANewStandaloneSongDoesNotReuseAnUnrelatedQueue() {
        withShuffledEngine { engine in
            let old = [song("queueSong01"), song("queueSong02")]
            let selected = song("newSong0001")
            engine.play(song: old[0], fromQueue: old)
            engine.play(song: selected)
            XCTAssertEqual(engine.queue.map(\.id), [selected.id])
            XCTAssertEqual(engine.currentIndex, 0)
            XCTAssertTrue(engine.shuffleEnabled)
        }
    }

    @MainActor func testDeletingTheNextShuffledSongLeavesAValidSelection() {
        withShuffledEngine { engine in
            let tracks = [song("queueSong01"), song("queueSong02")]
            engine.play(song: tracks[0], fromQueue: tracks)
            engine.removeFromQueue(at: 1)
            engine.next(userInitiated: false)
            XCTAssertEqual(engine.currentTrack?.id, tracks[0].id)
            XCTAssertEqual(engine.currentIndex, 0)
            engine.removeFromQueue(at: 0)
            engine.next(userInitiated: false)
            XCTAssertTrue(engine.queue.isEmpty)
        }
    }

    @MainActor func testStaleRecoveryFailureCannotFailAnotherSong() {
        withShuffledEngine { engine in
            let previous = song("queueSong01")
            let selected = song("newSong0001")
            engine.play(song: previous, fromQueue: [previous])
            engine.play(song: selected)
            let errorBefore = engine.lastError
            engine.updateRetryState(song: previous, streamURL: "", contentLength: nil)
            XCTAssertEqual(engine.currentTrack?.id, selected.id)
            XCTAssertEqual(engine.lastError, errorBefore)
        }
    }

    @MainActor func testModesSurviveRestartWithoutPersistingTheQueueAndBeatAnOlderQueueSnapshot() {
        let defaults = UserDefaults.standard
        let keys = ["playbackShuffleEnabled", "playbackRepeatMode", "persistentQueue"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(false, forKey: "persistentQueue")
        let first = AudioEngine()
        first.shuffleEnabled = true
        first.repeatMode = .one
        let restarted = AudioEngine()
        XCTAssertTrue(restarted.shuffleEnabled)
        XCTAssertEqual(restarted.repeatMode, .one)
        restarted.restorePlaybackState(.init(
            queue: [], autoplayQueue: [], currentIndex: 0, currentTime: 0,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
        XCTAssertTrue(restarted.shuffleEnabled, "An older queue must not overwrite the latest mode")
        XCTAssertEqual(restarted.repeatMode, .one)
        restarted.shuffleEnabled = false
        restarted.repeatMode = .all
        let nextRestart = AudioEngine()
        XCTAssertFalse(nextRestart.shuffleEnabled)
        XCTAssertEqual(nextRestart.repeatMode, .all)
    }
}
