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
