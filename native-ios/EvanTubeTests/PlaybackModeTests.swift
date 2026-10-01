import XCTest
@testable import LovelyMusic

final class PlaybackModeTests: XCTestCase {
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
