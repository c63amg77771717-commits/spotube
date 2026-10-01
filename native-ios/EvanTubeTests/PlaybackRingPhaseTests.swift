import XCTest
@testable import LovelyMusic

final class PlaybackRingPhaseTests: XCTestCase {
    func testPauseFreezesAndResumeContinuesTheRing() {
        var phase = PlaybackRingPhase()
        phase.setPlaying(true, at: 10)
        XCTAssertEqual(phase.degrees(at: 12), 144, accuracy: 0.001)
        phase.setPlaying(false, at: 12)
        XCTAssertEqual(phase.degrees(at: 50), 144, accuracy: 0.001)
        phase.setPlaying(true, at: 50)
        XCTAssertEqual(phase.degrees(at: 51), 216, accuracy: 0.001)
        phase.setPlaying(true, at: 51)
        XCTAssertEqual(phase.degrees(at: 52), 288, accuracy: 0.001)
    }
}
