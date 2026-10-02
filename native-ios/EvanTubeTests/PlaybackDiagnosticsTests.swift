import XCTest
@testable import LovelyMusic

final class PlaybackDiagnosticsTests: XCTestCase {
    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.json")
    }

    func testRecordsSurviveRelaunchAndKeepOnlyTheNewest100Events() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        for index in 0..<103 {
            store.record(.init(phase: .playerResponse, client: .iosSession,
                videoID: "4DARsEmUxMg", httpStatus: 200, playabilityStatus: "OK",
                timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        let restored = PlaybackDiagnostics(fileURL: file)
        XCTAssertEqual(restored.events.count, 100)
        XCTAssertEqual(restored.events.first?.timestamp, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(restored.events.last?.timestamp, Date(timeIntervalSince1970: 102))
    }

    func testReportUsesOnlySafeMetadataAndDistinguishesVerificationFromSignIn() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        let rawError = "登入帳戶以確認你不是機器人 SID=SECRET_COOKIE https://example.com/?key=SECRET_KEY"
        store.record(.init(phase: .playerResponse, client: .visionOS, videoID: "4DARsEmUxMg",
            httpStatus: 200, playabilityStatus: "LOGIN_REQUIRED", reason: .classify(rawError),
            hasAuth: false, visitorSource: .appFallback, hlsAvailable: false, formatCount: 0))
        store.record(.init(phase: .engineError, videoID: "SID=SECRET_COOKIE",
            playabilityStatus: "SECRET_KEY", reason: .classify("Sign in to play")))
        let data = try store.reportData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(PlaybackDiagnostics.Report.self, from: data)
        XCTAssertEqual(report.events.count, 2)
        XCTAssertEqual(report.events.first?.reason, .verificationRequired)
        XCTAssertEqual(report.events.last?.reason, .signInRequired)
        XCTAssertNil(report.events.last?.videoID)
        XCTAssertEqual(report.events.last?.playabilityStatus, "OTHER")
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET_COOKIE"))
        XCTAssertFalse(json.contains("SECRET_KEY"))
        XCTAssertFalse(json.contains("example.com"))
    }

    func testClearRemovesPersistedEvents() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(phase: .engineReady, videoID: "4DARsEmUxMg"))
        XCTAssertEqual(store.events.count, 1)
        try store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(PlaybackDiagnostics(fileURL: file).events.isEmpty)
    }
}
