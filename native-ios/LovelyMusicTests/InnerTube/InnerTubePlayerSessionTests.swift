import Foundation
import XCTest
@testable import LovelyMusic

final class InnerTubePlayerSessionTests: XCTestCase {
    private static let tvToken = "CgtTVVZJU0lUT1JfVE9LRU5fMzc="
    private static let watchToken = "CgtV0FUQ0hfVklTSVRPUl9UT0tFTg=="
    private static let authCookie = "SAPISID=fixture-sapisid; SID=fixture-sid"
    private static let keylessWebClient = YouTubeClient(
        clientName: "WEB_REMIX", clientId: "67", clientVersion: "1.20261021.01.00",
        apiKey: "", userAgent: YouTubeClient.userAgentWeb
    )
    private static let publicBootstrap =
        "<script>{\"INNERTUBE_API_KEY\":\"AIza\(String(repeating: "A", count: 35))\"," +
        "\"INNERTUBE_CONTEXT_CLIENT_VERSION\":\"1.20261021.01.00\"}</script>"
    private var sessions: [URLSession] = []
    private var defaultsSuites: [(UserDefaults, String)] = []

    override func tearDown() {
        sessions.forEach { $0.invalidateAndCancel() }
        sessions = []
        defaultsSuites.forEach { $0.0.removePersistentDomain(forName: $0.1) }
        defaultsSuites = []
        PlayerSessionHTTPFixture.reset()
        super.tearDown()
    }

    func testSessionContextRequiresYouTubeCookiesAndChangesGenerationOnlyWhenCookiesChange() async throws {
        let (api, defaults) = try makeAPI { _, loader in
            loader.fail(URLError(.unsupportedURL))
        }
        defaults.set("drive-only-account", forKey: "evantube_drive_enabled_account")
        var context = await api.playerSessionContext()
        XCTAssertFalse(context.isAuthenticated)
        XCTAssertEqual(context.generation, 0)

        await api.setCookie("VISITOR_INFO1_LIVE=visitor; SAPISID=only-one-cookie")
        context = await api.playerSessionContext()
        XCTAssertFalse(context.isAuthenticated)
        XCTAssertEqual(context.generation, 1)

        await api.setCookie(Self.authCookie)
        context = await api.playerSessionContext()
        XCTAssertTrue(context.isAuthenticated)
        XCTAssertEqual(context.generation, 2)
        await api.setCookie(Self.authCookie)
        let unchanged = await api.playerSessionContext()
        XCTAssertEqual(unchanged, context)

        await api.setCookie(nil)
        context = await api.playerSessionContext()
        XCTAssertFalse(context.isAuthenticated)
        XCTAssertEqual(context.generation, 3)
        await api.setCookie("SAPISID= ; SID=fixture-sid")
        let emptyValue = await api.playerSessionContext()
        XCTAssertFalse(emptyValue.isAuthenticated)
    }

    func testVisionOSUsesInjectedTVSessionAndNeverSendsSavedAuthentication() async throws {
        let (api, _) = try makeAPI(cookie: Self.authCookie) { request, loader in
            switch request.url?.path {
            case "/tv":
                loader.respond(body: Self.visitorHTML(Self.tvToken))
            case "/youtubei/v1/player":
                loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
            default:
                XCTFail("Unexpected request outside the injected TV/player fixture")
                loader.fail(URLError(.unsupportedURL))
            }
        }
        _ = try await api.playerWithVisionOS(videoId: "GUESTTV0037")
        let requests = PlayerSessionHTTPFixture.requests
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, ["/tv", "/youtubei/v1/player"])
        for request in requests {
            assertAnonymous(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SOCS=CAI")
        }
        let player = try XCTUnwrap(requests.last)
        XCTAssertEqual(player.value(forHTTPHeaderField: "X-Youtube-Client-Name"), "101")
        XCTAssertEqual(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), Self.tvToken)
        XCTAssertEqual(try bodyVisitor(player), Self.tvToken)
    }

    func testInvalidTVBootstrapFallsBackToAnonymousWatchVisitor() async throws {
        for invalid in InvalidBootstrap.allCases {
            let (api, _) = try makeAPI(cookie: Self.authCookie) { request, loader in
                switch request.url?.path {
                case "/tv":
                    invalid.respond(on: loader, validToken: Self.tvToken)
                case "/watch":
                    loader.respond(body: Self.visitorHTML(Self.watchToken))
                case "/youtubei/v1/player":
                    loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
                default:
                    loader.fail(URLError(.unsupportedURL))
                }
            }
            _ = try await api.playerWithVisionOS(videoId: "GUESTTV0037")
            let requests = PlayerSessionHTTPFixture.requests
            XCTAssertEqual(requests.map { $0.url?.path ?? "" },
                           ["/tv", "/watch", "/youtubei/v1/player"], "\(invalid)")
            for request in requests { assertAnonymous(request) }
            let player = try XCTUnwrap(requests.last)
            XCTAssertEqual(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
                           Self.watchToken, "\(invalid)")
            XCTAssertEqual(try bodyVisitor(player), Self.watchToken, "\(invalid)")
        }
    }

    func testInvalidWatchBootstrapIsNotAcceptedOrCachedAsAnInitializedSession() async throws {
        for invalid in InvalidBootstrap.allCases {
            let (api, defaults) = try makeAPI { request, loader in
                if request.url?.path == "/watch" {
                    let watchCount = PlayerSessionHTTPFixture.requests.filter {
                        $0.url?.path == "/watch"
                    }.count
                    if watchCount == 1 {
                        invalid.respond(on: loader, validToken: Self.tvToken)
                    } else {
                        loader.respond(body: Self.visitorHTML(Self.watchToken))
                    }
                } else if request.url?.path == "/youtubei/v1/player" {
                    loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
                } else {
                    loader.fail(URLError(.unsupportedURL))
                }
            }
            do {
                _ = try await api.playerWithSession(videoId: "WATCHBAD037")
                XCTFail("Invalid bootstrap must not be accepted: \(invalid)")
            } catch is InnerTubeError {
                // A bad page must never reach the IOS player POST.
            }
            XCTAssertNil(defaults.string(forKey: "innerTube.visitorData.lastGood"), "\(invalid)")
            XCTAssertFalse(PlayerSessionHTTPFixture.requests.contains {
                $0.url?.path == "/youtubei/v1/player"
            }, "\(invalid)")

            _ = try await api.playerWithSession(videoId: "WATCHBAD037")
            let requests = PlayerSessionHTTPFixture.requests
            XCTAssertEqual(requests.filter { $0.url?.path == "/watch" }.count, 2, "\(invalid)")
            let player = try XCTUnwrap(requests.last)
            XCTAssertEqual(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
                           Self.watchToken, "\(invalid)")
        }
    }

    func testSavedYouTubeSessionStillSignsIOSRequestAfterValidWatchBootstrap() async throws {
        let (api, _) = try makeAPI(cookie: Self.authCookie) { request, loader in
            if request.url?.path == "/watch" {
                loader.respond(body: Self.visitorHTML(Self.watchToken))
            } else if request.url?.path == "/youtubei/v1/player" {
                loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
            } else {
                loader.fail(URLError(.unsupportedURL))
            }
        }
        _ = try await api.playerWithSession(videoId: "AUTHIOS0037")
        let requests = PlayerSessionHTTPFixture.requests
        let watch = try XCTUnwrap(requests.first)
        let player = try XCTUnwrap(requests.last)
        XCTAssertTrue(watch.value(forHTTPHeaderField: "Cookie")?.contains("SAPISID=fixture-sapisid") == true)
        XCTAssertTrue(player.value(forHTTPHeaderField: "Cookie")?.contains("SID=fixture-sid") == true)
        XCTAssertTrue(player.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertEqual(player.value(forHTTPHeaderField: "X-Youtube-Client-Name"), "5")
        XCTAssertEqual(try bodyVisitor(player), Self.watchToken)
    }

    func testLogoutDiscardsPendingAuthenticatedWatchBootstrap() async throws {
        let started = expectation(description: "Authenticated watch request is pending")
        let held = HeldPlayerSessionResponse()
        defer { held.respond(body: Self.visitorHTML(Self.tvToken)) }
        let (api, defaults) = try makeAPI(cookie: Self.authCookie) { request, loader in
            if request.url?.path == "/watch" {
                let watchCount = PlayerSessionHTTPFixture.requests.filter {
                    $0.url?.path == "/watch"
                }.count
                if watchCount == 1 {
                    held.capture(loader)
                    started.fulfill()
                } else {
                    loader.respond(body: Self.visitorHTML(Self.watchToken))
                }
            } else {
                loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
            }
        }
        let oldRequest = Task { try await api.playerWithSession(videoId: "AUTHOLD0037") }
        defer { oldRequest.cancel() }
        await fulfillment(of: [started], timeout: 3)
        await api.setCookie(nil)
        held.respond(body: Self.visitorHTML(Self.tvToken))
        do {
            _ = try await oldRequest.value
            XCTFail("A response from the old authentication generation must be discarded")
        } catch is CancellationError {}
        XCTAssertNil(defaults.string(forKey: "innerTube.visitorData.lastGood"))
        XCTAssertFalse(PlayerSessionHTTPFixture.requests.contains {
            $0.url?.path == "/youtubei/v1/player"
        })

        _ = try await api.playerWithSession(videoId: "AUTHNEW0037")
        let requests = PlayerSessionHTTPFixture.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/watch" }.count, 2)
        let player = try XCTUnwrap(requests.last)
        XCTAssertNil(player.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse((player.value(forHTTPHeaderField: "Cookie") ?? "").contains("SAPISID="))
        XCTAssertEqual(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), Self.watchToken)
    }

    func testAuthenticationChangeDuringTVBootstrapPreventsOldPlayerPost() async throws {
        let started = expectation(description: "Anonymous TV request is pending")
        let held = HeldPlayerSessionResponse()
        defer { held.respond(body: Self.visitorHTML(Self.tvToken)) }
        let (api, _) = try makeAPI { request, loader in
            if request.url?.path == "/tv" {
                held.capture(loader)
                started.fulfill()
            } else {
                XCTFail("A stale TV request must not proceed to another request")
                loader.fail(URLError(.unsupportedURL))
            }
        }
        let oldRequest = Task { try await api.playerWithVisionOS(videoId: "OLDTV000037") }
        defer { oldRequest.cancel() }
        await fulfillment(of: [started], timeout: 3)
        await api.setCookie(Self.authCookie)
        held.respond(body: Self.visitorHTML(Self.tvToken))
        do {
            _ = try await oldRequest.value
            XCTFail("A guest request must not complete after switching to the saved session")
        } catch is CancellationError {}
        XCTAssertEqual(PlayerSessionHTTPFixture.requests.map { $0.url?.path ?? "" }, ["/tv"])
    }

    func testAuthenticationChangeDuringPublicWebBootstrapPreventsCrossSessionPlayerPost() async throws {
        let started = expectation(description: "Public WEB bootstrap is pending")
        let held = HeldPlayerSessionResponse()
        defer { held.respond(body: Self.publicBootstrap) }
        let (api, defaults) = try makeAPI { request, loader in
            if request.url?.path == "/sw.js_data" {
                loader.respond(body: ")]}'\n[[0,0,[\"\(Self.watchToken)\"]]]")
            } else if request.url?.host == "music.youtube.com", request.url?.path == "/" {
                held.capture(loader)
                started.fulfill()
            } else {
                XCTFail("An obsolete public bootstrap must not issue a player POST")
                loader.fail(URLError(.unsupportedURL))
            }
        }
        let oldRequest = Task {
            try await api.player(client: Self.keylessWebClient, videoId: "OLDWEB00037")
        }
        defer { oldRequest.cancel() }
        await fulfillment(of: [started], timeout: 3)
        await api.setCookie(Self.authCookie)
        held.respond(body: Self.publicBootstrap)
        do {
            _ = try await oldRequest.value
            XCTFail("The player request must retain the session that began its bootstrap")
        } catch is CancellationError {}
        XCTAssertNil(defaults.string(forKey: "innerTube.visitorData.lastGood"))
        XCTAssertFalse(PlayerSessionHTTPFixture.requests.contains {
            $0.url?.path == "/youtubei/v1/player"
        })
        for request in PlayerSessionHTTPFixture.requests { assertAnonymous(request) }
    }

    func testDegradedPublicWebPlayerUsesOneAnonymousVisitorInBodyAndHeader() async throws {
        let (api, _) = try makeAPI { request, loader in
            if request.url?.host == "music.youtube.com", request.url?.path == "/" {
                // The public client config is usable but contains no visitor.
                loader.respond(body: Self.publicBootstrap)
            } else if request.url?.path == "/youtubei/v1/player" {
                loader.respond(body: #"{"playabilityStatus":{"status":"OK"}}"#)
            } else {
                loader.respond(status: 503, body: "{}")
            }
        }
        for _ in 0..<2 {
            _ = try await api.player(client: Self.keylessWebClient, videoId: "GUESTWEB037")
        }
        let degraded = await api.degradedVisitorState
        XCTAssertTrue(degraded)
        let player = try XCTUnwrap(PlayerSessionHTTPFixture.requests.last {
            $0.url?.path == "/youtubei/v1/player"
        })
        assertAnonymous(player)
        let header = try XCTUnwrap(player.value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
        try assertFreshGeneratedVisitorData(header)
        XCTAssertEqual(try bodyVisitor(player), header,
                       "A degraded refresh must not generate a new identity between body and header")
    }

    private func makeAPI(
        cookie: String? = nil, handler: @escaping PlayerSessionHTTPFixture.Handler
    ) throws -> (InnerTubeAPI, UserDefaults) {
        PlayerSessionHTTPFixture.reset(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayerSessionHTTPFixture.self]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        let name = "InnerTubePlayerSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaultsSuites.append((defaults, name))
        return (InnerTubeAPI(session: session, userDefaults: defaults, cookie: cookie), defaults)
    }

    private static func visitorHTML(_ token: String) -> String {
        "<script>{\"visitorData\":\"\(token)\"}</script>"
    }

    private func assertAnonymous(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
        let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookies.contains("SAPISID="), file: file, line: line)
        XCTAssertFalse(cookies.contains("SID="), file: file, line: line)
    }

    private func bodyVisitor(_ request: URLRequest) throws -> String? {
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = body["context"] as? [String: Any]
        let client = context?["client"] as? [String: Any]
        return client?["visitorData"] as? String
    }

    private enum InvalidBootstrap: CaseIterable {
        case httpFailure, redirectedHost, malformedToken, missingToken

        func respond(on loader: PlayerSessionHTTPFixture, validToken: String) {
            switch self {
            case .httpFailure:
                loader.respond(status: 503, body: InnerTubePlayerSessionTests.visitorHTML(validToken))
            case .redirectedHost:
                loader.respond(url: URL(string: "https://consent.google.com/"),
                               body: InnerTubePlayerSessionTests.visitorHTML(validToken))
            case .malformedToken:
                loader.respond(body: InnerTubePlayerSessionTests.visitorHTML("not-a-visitor-token"))
            case .missingToken:
                loader.respond(body: "<html>Consent page without visitor data</html>")
            }
        }
    }
}

private final class PlayerSessionHTTPFixture: URLProtocol {
    typealias Handler = (URLRequest, PlayerSessionHTTPFixture) -> Void
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    private static var handler: Handler?

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func reset(handler: Handler? = nil) {
        lock.lock()
        defer { lock.unlock() }
        captured = []
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = data
        }
        Self.lock.lock()
        Self.captured.append(capturedRequest)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            fail(URLError(.unsupportedURL))
            return
        }
        handler(capturedRequest, self)
    }

    func respond(status: Int = 200, url: URL? = nil, body: String) {
        guard let responseURL = url ?? request.url,
              let response = HTTPURLResponse(url: responseURL, statusCode: status,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]) else {
            fail(URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
    override func stopLoading() {}
}

private final class HeldPlayerSessionResponse {
    private let lock = NSLock()
    private var loader: PlayerSessionHTTPFixture?

    func capture(_ value: PlayerSessionHTTPFixture) {
        lock.lock()
        defer { lock.unlock() }
        loader = value
    }

    func respond(body: String) {
        lock.lock()
        let captured = loader
        loader = nil
        lock.unlock()
        captured?.respond(body: body)
    }
}
