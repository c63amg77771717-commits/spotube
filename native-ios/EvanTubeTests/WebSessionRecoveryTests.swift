import SwiftUI
import WebKit
import XCTest
@testable import LovelyMusic

@MainActor
final class WebSessionRecoveryTests: XCTestCase {
    func testClosingWebPlaybackPersistsRotatedBrowserCookies() async throws {
        let auth = YouTubeAuthManager()
        let original = auth.getAuthCookies()
        defer { restore(auth, cookies: original) }
        XCTAssertTrue(auth.storeAuthCookies(cookies(value: "old-test-only")))
        let view = YouTubePlaybackWebView(videoID: "sessiontest", authManager: auth)
        let coordinator = view.makeCoordinator()
        let webView = makeWebView()
        for cookie in cookies(value: "new-test-only") {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let updated = expectation(description: "Browser session is saved and native observers are notified")
        let observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if auth.cookieHeaderString() == "SAPISID=new-test-only; SID=new-test-only" {
                    updated.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        YouTubePlaybackWebView.dismantleUIView(webView, coordinator: coordinator)
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(auth.cookieHeaderString(), "SAPISID=new-test-only; SID=new-test-only",
                       "Native retry must use the session updated by the visible YouTube page")
    }

    func testClosingAnOldWebViewCannotUndoExplicitLogout() async throws {
        let auth = YouTubeAuthManager()
        let original = auth.getAuthCookies()
        defer { restore(auth, cookies: original) }
        XCTAssertTrue(auth.storeAuthCookies(cookies(value: "old-test-only")))
        let coordinator = YouTubePlaybackWebView(videoID: "sessiontest", authManager: auth).makeCoordinator()
        let webView = makeWebView()
        for cookie in cookies(value: "new-test-only") {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        auth.logout()
        let restored = expectation(description: "Stale browser must not restore a logged-out account")
        restored.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in if auth.isLoggedIn { restored.fulfill() } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        YouTubePlaybackWebView.dismantleUIView(webView, coordinator: coordinator)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(auth.cookieHeaderString())
    }

    func testRetryRetainsProgressQueueAndShuffle() async throws {
        let keys = ["persistentQueue", "playbackShuffleEnabled", "playbackRepeatMode", "crossfade_duration", "isAutoplayEnabled"]
        let backup = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = backup[index] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(true, forKey: "playbackShuffleEnabled")
        UserDefaults.standard.set("off", forKey: "playbackRepeatMode")
        UserDefaults.standard.set(0, forKey: "crossfade_duration")
        UserDefaults.standard.set(false, forKey: "isAutoplayEnabled")
        let engine = AudioEngine()
        defer { engine.stop() }
        let repository = WebRecoveryRepository()
        let model = PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: repository),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
        var selected = Song(id: "recovery001", title: "Fixture", artistName: "Fixture", artistId: nil,
                            albumName: nil, albumId: nil, duration: 360, thumbnailURL: nil)
        selected.streamURL = "https://example.test/stale-stream?expire=1"
        selected.streamContentLength = 1234
        let next = Song(id: "recovery002", title: "Next fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 360, thumbnailURL: nil)
        engine.restorePlaybackState(.init(queue: [selected, next], autoplayQueue: [], currentIndex: 0,
            currentTime: 269, wasPlaying: false, shuffleEnabled: true, repeatMode: "off", savedAt: Date()))
        model.prepareForWebPlayback()
        XCTAssertEqual(engine.currentTime, 269, accuracy: 0.001)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
        let requested = expectation(description: "Manual retry requests a fresh stream")
        engine.streamURLResolver = { _ in
            requested.fulfill()
            throw InnerTubeError.videoUnavailable(reason: "Sign in to confirm you're not a bot")
        }
        model.retryCurrentSong()
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(engine.currentTime, 269, accuracy: 0.001, "Retry must not reset the saved progress")
        XCTAssertEqual(engine.queue.map(\.id), [selected.id, next.id])
        XCTAssertTrue(engine.shuffleEnabled)
    }

    func testClosingAnOldWebViewCannotReplaceANewerLogin() async throws {
        let auth = YouTubeAuthManager()
        let original = auth.getAuthCookies()
        defer { restore(auth, cookies: original) }
        XCTAssertTrue(auth.storeAuthCookies(cookies(value: "old-test-only")))
        let coordinator = YouTubePlaybackWebView(videoID: "sessiontest", authManager: auth).makeCoordinator()
        let webView = makeWebView()
        for cookie in cookies(value: "browser-test-only") {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        XCTAssertTrue(auth.storeAuthCookies(cookies(value: "newer-login-test-only")))
        let overwritten = expectation(description: "A newer login must take precedence over an old web page")
        overwritten.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if auth.cookieHeaderString()?.contains("browser-test-only") == true { overwritten.fulfill() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        YouTubePlaybackWebView.dismantleUIView(webView, coordinator: coordinator)
        await fulfillment(of: [overwritten], timeout: 1)
        XCTAssertEqual(auth.cookieHeaderString(), "SAPISID=newer-login-test-only; SID=newer-login-test-only")
    }

    func testPendingTransientRetryCannotRestartNativePlaybackBehindWebPage() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        let model = makeModel(engine: engine)
        let selected = Song(id: "webretry001", title: "Fixture", artistName: "Fixture", artistId: nil,
                            albumName: nil, albumId: nil, duration: 360, thumbnailURL: nil)
        var requests = 0
        let unexpected = expectation(description: "Old retry must not run behind the browser")
        unexpected.isInverted = true
        engine.streamURLResolver = { _ in
            requests += 1
            if requests == 1 { throw InnerTubeError.timeout }
            if requests > 2 { unexpected.fulfill() }
            throw InnerTubeError.videoUnavailable(reason: "Sign in to confirm you're not a bot")
        }
        model.play(song: selected, fromQueue: [selected])
        for _ in 0..<100 where model.streamError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.streamError, "Transient failure must schedule the delayed retry")
        model.retryCurrentSong()
        for _ in 0..<100 where model.streamErrorCategory != .verificationRequired {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.streamErrorCategory, .verificationRequired)
        model.prepareForWebPlayback()
        await fulfillment(of: [unexpected], timeout: 1.3)
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isBuffering)
    }

    func testRawReadinessRetainsSeekUntilSuccessfulRemuxHandoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("raw.mp4")
        let local = directory.appendingPathComponent("remuxed.m4a")
        _ = try await DeterministicFMP4Fixture.generate(configuration: .twentySeconds,
            outputURL: raw, timeout: .seconds(30))
        let remuxed = await AudioEngine.remuxToStandardMP4(source: raw, destination: local)
        XCTAssertTrue(remuxed)
        let engine = AudioEngine()
        defer { engine.stop() }
        let selected = Song(id: "rawretry001", title: "Fixture", artistName: "Fixture", artistId: nil,
                            albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        engine.restorePlaybackState(.init(queue: [selected], autoplayQueue: [], currentIndex: 0,
            currentTime: 12, wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
        let startedAt = Date()
        engine.playRawFile(raw, song: selected, seekTo: 12)
        for _ in 0..<500 where !PlaybackDiagnostics.shared.events.contains(where: {
            $0.phase == .engineReady && $0.videoID == selected.id && $0.timestamp >= startedAt
        }) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(PlaybackDiagnostics.shared.events.contains(where: {
            $0.phase == .engineReady && $0.videoID == selected.id && $0.timestamp >= startedAt
        }), "The actual raw AVPlayerItem must become ready before handoff")
        XCTAssertEqual(engine.pendingSeekTime, 12, "An unseekable raw item must retain the target")
        engine.handoffToLocalFile(local, song: selected)
        for _ in 0..<500 where abs(engine.guardedObservedPosition - 12) > 0.1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.guardedObservedPosition, 12, accuracy: 0.1,
                       "The real AVPlayer must seek the remuxed file to the saved progress")
        XCTAssertEqual(engine.localFileURL, local)
        XCTAssertFalse(engine.isStreamingMode)
        XCTAssertFalse(engine.isPlaying, "Remux handoff must also preserve an explicit pause")
    }

    private func makeModel(engine: AudioEngine) -> PlayerViewModel {
        let repository = WebRecoveryRepository()
        return PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: repository),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }

    private func cookies(value: String) -> [HTTPCookie] {
        ["SID", "SAPISID"].map { name in
            HTTPCookie(properties: [.name: name, .value: value, .domain: ".youtube.com", .path: "/",
                                   .expires: Date().addingTimeInterval(600)])!
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func restore(_ auth: YouTubeAuthManager, cookies: [HTTPCookie]) {
        if YouTubeAuthManager.hasActiveAuthCookies(cookies) { auth.storeAuthCookies(cookies) }
        else { auth.logout() }
    }
}

private struct WebRecoveryRepository: PlayerRepositoryProtocol, LyricsRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw InnerTubeError.videoUnavailable(reason: "Sign in to confirm you're not a bot")
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { nil }
}
