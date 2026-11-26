import XCTest
@testable import LovelyMusic

final class Build53PlaybackTests: XCTestCase {
    func testRepeatedDiagnosticsKeepTheEarlierHistory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("build53-diagnostics-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = RuntimeDiagnosticLog(fileURL: file, capacity: 6)
        log.append("termination hint relaunch-while-backgrounded")
        for _ in 0..<30 {
            log.append("retry deduped video=H_4e40isYTY reason=unexpected-pause")
        }
        let lines = log.snapshot()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("relaunch-while-backgrounded"))
        XCTAssertTrue(lines[1].contains("retry deduped video=H_4e40isYTY reason=unexpected-pause ×30"))
    }

    func testUnexpectedPauseBurstSchedulesOneKickThenWaits() {
        var admission = UnexpectedPauseAdmission()
        let start: TimeInterval = 1_000
        XCTAssertEqual(admission.admit(now: start, recoveryBusy: false), .kick)
        for offset in 1...20 {
            XCTAssertEqual(
                admission.admit(now: start + Double(offset) / 100, recoveryBusy: false),
                .ignore
            )
        }
        XCTAssertEqual(admission.admit(now: start + 1.1, recoveryBusy: true), .ignore)
        XCTAssertEqual(admission.admit(now: start + 1.2, recoveryBusy: false), .recover)
        XCTAssertEqual(admission.admit(now: start + 1.3, recoveryBusy: false), .ignore)
    }

    func testAutomaticResolveOfTheSameVideoCannotRepeatWithinTwoSeconds() {
        var gate = AutomaticResolveGate()
        XCTAssertTrue(gate.allow(videoID: "BqSvGxKsdps", now: 10, inFlight: false))
        XCTAssertFalse(gate.allow(videoID: "BqSvGxKsdps", now: 10.9, inFlight: false))
        XCTAssertFalse(gate.allow(videoID: "BqSvGxKsdps", now: 11, inFlight: true))
        XCTAssertTrue(gate.allow(videoID: "BqSvGxKsdps", now: 12, inFlight: false))
        XCTAssertTrue(gate.allow(videoID: "other", now: 12, inFlight: false))
    }

    func testSignInRequiredDoesNotAdvanceUnlessTheListenerChooses() {
        XCTAssertTrue(ListenerPlaybackChoice.isSignInRequired("Video unavailable: LOGIN_REQUIRED"))
        XCTAssertTrue(ListenerPlaybackChoice.isSignInRequired("engineError signInRequired"))
        XCTAssertFalse(ListenerPlaybackChoice.isSignInRequired("HTTP error: 404"))
        XCTAssertFalse(ListenerPlaybackChoice.allowsAutomaticAdvance(signInRequired: true, userInitiated: false))
        XCTAssertTrue(ListenerPlaybackChoice.allowsAutomaticAdvance(signInRequired: true, userInitiated: true))
        XCTAssertTrue(ListenerPlaybackChoice.allowsAutomaticAdvance(signInRequired: false, userInitiated: false))
    }
}
