import XCTest
@testable import LovelyMusic

final class PlaybackErrorTests: XCTestCase {
    func testUnavailableStreamDoesNotImplyRegionOrLogin() {
        for message in ["No audio stream available", "Video unavailable: Unknown", "沒有可用的音訊串流"] {
            XCTAssertEqual(PlaybackErrorCategory.classify(message), .unknown)
        }
        XCTAssertEqual(PlaybackErrorCategory.classify("Video unavailable: This video is not available in your country"), .regionBlocked)
        XCTAssertEqual(PlaybackErrorCategory.classify("Video unavailable: This video has been removed"), .songRemoved)
        XCTAssertEqual(PlaybackErrorCategory.classify("Sign in to confirm you're not a bot"), .verificationRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("影片無法播放：登入帳戶以確認你不是機器人"), .verificationRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("請登入 YouTube"), .authRequired)
        XCTAssertEqual(PlaybackErrorCategory.classify("無法在你的地區播放"), .regionBlocked)
        XCTAssertEqual(PlaybackErrorCategory.classify("這首歌已從音源移除"), .songRemoved)
        XCTAssertEqual(PlaybackErrorCategory.classify("Network error: TLS authentication failed"), .noInternet)
        XCTAssertEqual(PlaybackErrorCategory.classify("尚未設定線上音源"), .sourceNotConfigured)
    }

    @MainActor func testExpiredOrVisitorCookiesDoNotMeanSignedIn() {
        let now = Date()
        func cookie(_ name: String, expires: Date) -> HTTPCookie {
            HTTPCookie(properties: [
                .name: name, .value: "test-only", .domain: ".youtube.com",
                .path: "/", .expires: expires,
            ])!
        }
        let future = now.addingTimeInterval(600)
        let past = now.addingTimeInterval(-600)
        XCTAssertFalse(YouTubeAuthManager.hasActiveAuthCookies([cookie("VISITOR_INFO1_LIVE", expires: future)], at: now))
        XCTAssertFalse(YouTubeAuthManager.hasActiveAuthCookies([cookie("SAPISID", expires: past), cookie("SID", expires: future)], at: now))
        XCTAssertTrue(YouTubeAuthManager.hasActiveAuthCookies([cookie("SAPISID", expires: future), cookie("SID", expires: future)], at: now))
    }

    func testMissingClientKeyStopsBeforeSendingRequest() async throws {
        let client = YouTubeClient(
            clientName: "TEST", clientId: "0", clientVersion: "1", apiKey: "",
            userAgent: "EvanTube-configuration-check"
        )
        do {
            _ = try await InnerTubeAPI().player(client: client, videoId: "configuration-check")
            XCTFail("A request with no source key must fail locally")
        } catch InnerTubeError.sourceNotConfigured {
            // Missing configuration is distinct from account or region restrictions.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor func testGoogleAndLookalikeCookiesCannotCompleteYouTubeLogin() {
        func cookies(_ domain: String) -> [HTTPCookie] {
            ["SAPISID", "SID"].map { name in
                HTTPCookie(properties: [
                    .name: name, .value: "test-only", .domain: domain, .path: "/",
                ])!
            }
        }
        for domain in [".google.com", ".youtube.com.example.com", ".notyoutube.com"] {
            XCTAssertFalse(YouTubeAuthManager.hasActiveAuthCookies(cookies(domain)), domain)
        }
        XCTAssertTrue(YouTubeAuthManager.hasActiveAuthCookies(cookies(".youtube.com")))
    }

    func testPlayerBootstrapReceivesCurrentAuthWithoutDuplicateCookies() async throws {
        let storage = HTTPCookieStorage.shared
        let oldCookies = storage.cookies ?? []
        let stale = HTTPCookie(properties: [
            .name: "SID", .value: "stale-test-only", .domain: ".youtube.com", .path: "/",
        ])!
        storage.setCookie(stale)
        defer {
            for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
            for cookie in oldCookies { storage.setCookie(cookie) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackAuthProtocol.self]
        let api = InnerTubeAPI(session: URLSession(configuration: configuration))
        await api.setCookie("SID=current-test-only; SAPISID=sapisid-test-only")
        _ = try await api.playerWithSession(videoId: "auth-check")
    }

    func testMissingFallbackKeysPreserveTheSourcePlayabilityReason() async throws {
        for reason in ["Sign in to confirm you're not a bot", "This video is not available in your country"] {
            let repository = PlayerRepository(api: PlayabilityFailureAPI(reason: reason))
            do {
                _ = try await repository.resolveStreamDescriptor(videoId: "reason-check", quality: .medium, requestHeaders: [:])
                XCTFail("The source rejected playback")
            } catch InnerTubeError.videoUnavailable(let actualReason) {
                XCTAssertEqual(actualReason, reason)
            } catch {
                XCTFail("The original source reason was replaced: \(error)")
            }
        }
    }
}

private final class PlaybackAuthProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let sidValues = (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .components(separatedBy: "; ").filter { $0.hasPrefix("SID=") }
        XCTAssertEqual(sidValues, ["SID=current-test-only"],
                       "Both watch bootstrap and player must receive the current YouTube session exactly once")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = request.httpMethod == "POST"
            ? #"{"playabilityStatus":{"status":"OK"}}"#
            : #"<html><script>{"visitorData":"test-visitor"}</script></html>"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PlayabilityFailureAPI: PlayerAPIClient {
    var reason = "Sign in required"

    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["playabilityStatus": ["status": "UNPLAYABLE", "reason": reason]])
    }
    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data {
        throw InnerTubeError.sourceNotConfigured
    }
    func playerWithVisionOS(videoId: String) async throws -> Data {
        throw InnerTubeError.noStreamAvailable
    }
    func resetSession() async {}
}
