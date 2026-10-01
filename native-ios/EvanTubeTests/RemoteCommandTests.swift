import MediaPlayer
import XCTest
@testable import LovelyMusic

final class RemoteCommandTests: XCTestCase {
    @MainActor func testSystemTransportUsesTrackNavigationAndAllowsSeeking() {
        let manager = RemoteCommandManager()
        manager.setup()
        defer { manager.tearDown() }
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.previousTrackCommand.isEnabled)
        XCTAssertTrue(center.nextTrackCommand.isEnabled)
        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertFalse(center.skipBackwardCommand.isEnabled)
        XCTAssertFalse(center.skipForwardCommand.isEnabled)
    }
}
