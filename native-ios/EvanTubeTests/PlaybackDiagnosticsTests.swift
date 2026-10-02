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
        let exported = try store.exportReport()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        try store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(PlaybackDiagnostics(fileURL: file).events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
    }

    func testSourceResponseCaptureNeverRetainsRawReasonsOrStreamURLs() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        let response = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot SECRET_COOKIE"},"streamingData":{"hlsManifestUrl":"https://example.com/SECRET_URL","formats":[{"url":"SECRET_URL"}],"adaptiveFormats":[{"url":"SECRET_URL"}]},"headers":{"Cookie":"SECRET_COOKIE"}}"#.utf8)
        store.recordPlayerResponse(response, httpStatus: 200, client: .iosSession,
            videoID: "4DARsEmUxMg", hasAuth: true, sessionAgeSeconds: 30, visitorSource: .watchPage)
        XCTAssertEqual(store.events.first?.reason, .verificationRequired)
        XCTAssertEqual(store.events.first?.formatCount, 2)
        XCTAssertEqual(store.events.first?.hasAuth, true)
        XCTAssertEqual(store.events.first?.sessionAgeSeconds, 30)
        let exported = try store.exportReport()
        let data = try Data(contentsOf: exported)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET_"))
        XCTAssertEqual(try exported.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRelaunchRemovesAnInterruptedSharingSnapshot() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(phase: .engineReady, videoID: "4DARsEmUxMg"))
        let snapshot = try store.exportReport()
        store.record(.init(phase: .enginePlaying, videoID: "4DARsEmUxMg"))
        let restored = PlaybackDiagnostics(fileURL: file)
        XCTAssertEqual(restored.events.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path),
            "An interrupted share must not retain an older snapshot indefinitely")
    }

    func testMediaHttpFailureIsCapturedBeforeRecoveryWithoutRawLogContents() {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.recordMediaFailure(videoID: "4DARsEmUxMg", statusCode: -403, errorCode: -12660)
        XCTAssertEqual(store.events.first?.phase, .engineError)
        XCTAssertEqual(store.events.first?.httpStatus, 403)
        XCTAssertEqual(store.events.first?.transportErrorCode, -12660)
    }

    @MainActor func testStartingAnotherSongDoesNotReuseThePreviousFailedSongID() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "persistentQueue")
        defaults.set(false, forKey: "persistentQueue")
        defer {
            if let original { defaults.set(original, forKey: "persistentQueue") }
            else { defaults.removeObject(forKey: "persistentQueue") }
        }
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { _ in throw InnerTubeError.timeout }
        engine.play(song: Song(id: "failSong001", title: "First", artistName: "Test"))
        for _ in 0..<100 where engine.lastFailedSongId == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.lastFailedSongId, "failSong001")
        engine.streamURLResolver = nil
        engine.play(song: Song(id: "nextSong001", title: "Second", artistName: "Test"))
        XCTAssertNil(engine.lastFailedSongId)
        XCTAssertEqual(PlaybackDiagnostics.shared.events.last(where: { $0.phase == .engineError })?.videoID, "nextSong001")
    }

    func testFallbackRequestReportsItsActualWatchVisitorSource() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticVisitorProtocol.self]
        let api = InnerTubeAPI(session: URLSession(configuration: configuration))
        _ = try await api.playerWithSession(videoId: "visitorTest")
        let configured = YouTubeClient(clientName: "IOS", clientId: "5", clientVersion: "test",
            apiKey: "test-only", userAgent: "test-only")
        _ = try await api.player(client: configured, videoId: "visitorTest")
        let result = PlaybackDiagnostics.shared.events.last {
            $0.phase == .playerResponse && $0.videoID == "visitorTest" && $0.client == .ios
        }
        XCTAssertEqual(result?.visitorSource, .watchPage)
    }

    func testRelaunchSanitizesUnexpectedPersistedStringsBeforeExport() throws {
        let file = fileURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(phase: .playerResponse, videoID: "4DARsEmUxMg", playabilityStatus: "OK"))
        var json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        json = json.replacingOccurrences(of: "4DARsEmUxMg", with: "SECRET_COOKIE")
            .replacingOccurrences(of: "OK", with: "SECRET_KEY")
        try Data(json.utf8).write(to: file)
        let restored = PlaybackDiagnostics(fileURL: file)
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertNil(restored.events.first?.videoID)
        XCTAssertEqual(restored.events.first?.playabilityStatus, "OTHER")
        XCTAssertFalse(String(decoding: try restored.reportData(), as: UTF8.self).contains("SECRET_"))
    }
}

private final class DiagnosticVisitorProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = request.httpMethod == "POST" ? #"{"playabilityStatus":{"status":"OK"}}"#
            : #"<html><script>{"visitorData":"CgtWATCH_PAGE_01234567890123456789"}</script></html>"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
