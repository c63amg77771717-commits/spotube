import XCTest
@testable import LovelyMusic

/// Tests for `polish-B2` (visitorData hardening) and `polish-B3` (cache-policy bypass).
/// Uses a custom `URLProtocol` stub registered on the `URLSessionConfiguration` passed
/// into `InnerTubeAPI` so we can capture every outbound `URLRequest` and serve canned
/// responses without hitting the network.
final class InnerTubeVisitorDataTests: XCTestCase {

    // MARK: - Test infrastructure

    private var defaultsSuiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "InnerTubeVisitorDataTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        URLProtocolStub.reset()
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeAPI(handler: @escaping URLProtocolStub.Handler) -> InnerTubeAPI {
        URLProtocolStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        // Ensure URLCache is a no-op for tests so cachePolicy assertions are meaningful.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        return InnerTubeAPI(session: session, userDefaults: userDefaults)
    }

    // MARK: - 1. Header is plain ASCII, never percent-encoded

    func test_visitorDataHeader_isPlainAscii_neverPercentEncoded() async throws {
        // Both values encode the same protobuf shape: an 11-byte visitor ID
        // and a timestamp. A letter/digit first byte yields Cgt/Cgs respectively.
        // Preserve '=' padding in the header rather than percent-encoding it.
        for storedToken in [VisitorDataTestFixtures.letterVisitor, VisitorDataTestFixtures.digitVisitor] {
            userDefaults.removePersistentDomain(forName: defaultsSuiteName)
            URLProtocolStub.reset()
            let swJsData = ")]}'\n[[0,0,[\"\(storedToken)\"]]]"
            let api = makeAPI { request in
                if let bootstrap = VisitorDataTestFixtures.publicWebBootstrapResponse(for: request) {
                    return bootstrap
                }
                if request.url?.path == "/sw.js_data" {
                    let body = Data(swJsData.utf8)
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: nil)!
                    return (response, body)
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data("{}".utf8))
            }

            _ = try await api.search(query: "abc")

            let captured = URLProtocolStub.capturedRequests
            XCTAssertEqual(captured.filter { $0.url?.path == "/sw.js_data" }.count, 1)
            let searchRequest = try XCTUnwrap(captured.first {
                $0.url?.host == "music.youtube.com" && $0.url?.path == "/youtubei/v1/search"
            })

            let headerValue = searchRequest.value(forHTTPHeaderField: "X-Goog-Visitor-Id")
            XCTAssertEqual(headerValue, storedToken,
                "Header must be the raw stored value with '=' intact, not URL-encoded")
            XCTAssertFalse(headerValue?.contains("%3D") ?? false,
                "Header must not URL-encode '=' to '%3D'")
        }
    }

    // MARK: - 2. Empty header when no cache and refresh fails

    func test_visitorDataFallback_usesDefault_whenNoCacheAndRefreshFails() async throws {
        // Visitor refresh fails, but the homepage still supplies public client
        // configuration without a visitor token. The search must use a fresh
        // generated visitor without requiring an embedded API key.
        let api = makeAPI { request in
            if let bootstrap = VisitorDataTestFixtures.publicWebBootstrapResponse(for: request) {
                return bootstrap
            }
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try await api.search(query: "anything")

        guard let searchRequest = URLProtocolStub.capturedRequests.first(where: {
            $0.url?.host == "music.youtube.com" && $0.httpMethod == "POST"
        }) else {
            XCTFail("No search request captured")
            return
        }

        let headerValue = searchRequest.value(forHTTPHeaderField: "X-Goog-Visitor-Id")
        try assertFreshGeneratedVisitorData(headerValue)
    }

    // MARK: - 3. Persistence write/read within TTL

    func test_visitorDataPersistence_writeReadRoundtrip_withinTTL() async throws {
        // Pre-seed UserDefaults with a value written 12 hours ago (within 24h TTL).
        let token = "CgtPRVJTSVNURURfVE9LRU5fWFla"
        let twelveHoursAgo = Date().timeIntervalSince1970 - (12 * 3600)
        userDefaults.set(token, forKey: "innerTube.visitorData.lastGood")
        userDefaults.set(twelveHoursAgo, forKey: "innerTube.visitorData.lastGoodAt")

        // Build API — hydration happens in init.
        let api = makeAPI { request in
            // All refresh sources fail so they cannot overwrite the persisted value.
            if request.url?.host == "music.youtube.com" && request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let hydrated = await api.visitorData
        XCTAssertEqual(hydrated, token, "Persisted visitorData within TTL must hydrate on init")
    }

    // MARK: - 4. Persistence expires after 24 hours

    func test_visitorDataPersistence_expires_after24Hours() async throws {
        // Pre-seed with a value written 2 days ago (beyond 24h TTL).
        let token = "CgtFWFBJUkVEX1RPS0VO"
        let twoDaysAgo = Date().timeIntervalSince1970 - (2 * 86_400)
        userDefaults.set(token, forKey: "innerTube.visitorData.lastGood")
        userDefaults.set(twoDaysAgo, forKey: "innerTube.visitorData.lastGoodAt")

        let api = makeAPI { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data())
        }

        let hydrated = await api.visitorData
        // Expired token is not hydrated — visitorData falls back to generated default token
        XCTAssertNotEqual(hydrated, token, "Expired persisted visitorData must NOT hydrate (2 days > 24h TTL)")
        try assertFreshGeneratedVisitorData(hydrated)
    }

    // MARK: - 5. Cache policy is reloadIgnoringLocalCacheData on every InnerTube POST

    func test_cachePolicy_isReloadIgnoringLocal_onAllInnerTubePOSTs() async throws {
        // Stub sw.js_data so refresh can succeed quickly.
        let swJsData = ")]}'\n[[0,0,[\"\(VisitorDataTestFixtures.letterVisitor)\"]]]"
        let api = makeAPI { request in
            if let bootstrap = VisitorDataTestFixtures.publicWebBootstrapResponse(for: request) {
                return bootstrap
            }
            if request.url?.path == "/sw.js_data" {
                let body = Data(swJsData.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, body)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try await api.search(query: "q1")
        _ = try await api.browse(browseId: "FEmusic_home")

        let postRequests = URLProtocolStub.capturedRequests.filter {
            $0.httpMethod == "POST" && $0.url?.host == "music.youtube.com"
        }
        XCTAssertGreaterThanOrEqual(postRequests.count, 2,
            "Expected at least one search and one browse POST")
        for request in postRequests {
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData,
                "POST to \(request.url?.path ?? "") must bypass URLCache")
        }
    }

    // MARK: - 6. Degraded state set after two failures, cleared on success

    func test_degradedState_setsAfterTwoFailures_andClearsOnSuccess() async throws {
        // Use a counter so we can flip from failure → success on the same stub.
        let state = StubState()

        let api = makeAPI { request in
            if let bootstrap = VisitorDataTestFixtures.publicWebBootstrapResponse(for: request) {
                return bootstrap
            }
            if request.url?.path == "/sw.js_data" {
                let shouldFail = state.shouldFailServiceWorker()
                let code = shouldFail ? 500 : 200
                var body = Data()
                if !shouldFail {
                    body = Data(")]}'\n[[0,0,[\"\(VisitorDataTestFixtures.letterVisitor)\"]]]".utf8)
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, body)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        // Two refresh cycles fail. The HTML fallback has no visitor, while its
        // public client config keeps the downstream searches operational.
        state.failServiceWorkerCalls = 2
        _ = try await api.search(query: "first")
        _ = try await api.search(query: "second")

        let degradedAfterFailures = await api.degradedVisitorState
        XCTAssertTrue(degradedAfterFailures, "Expected degraded=true after 2 ensure-cycle failures")

        // Now allow success on the next refresh — visitorDataTimestamp is nil
        // so the next call re-enters refresh; success should clear degraded.
        state.failServiceWorkerCalls = 0
        _ = try await api.search(query: "third")

        let degradedAfterSuccess = await api.degradedVisitorState
        XCTAssertFalse(degradedAfterSuccess, "Expected degraded=false after recovery")
    }
}

// MARK: - URLProtocolStub

/// Captures every outgoing `URLRequest` and serves a canned response generated by
/// `handler`. Thread-safe; intentionally minimal — no streaming, no chunking.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _capturedRequests = []
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._capturedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Mutable state holder for handler closures

/// Small reference container used to share mutable counters with `URLProtocolStub.handler`
/// closures (which are otherwise capture-by-value).
private final class StubState: @unchecked Sendable {
    var failServiceWorkerCalls: Int = 0

    func shouldFailServiceWorker() -> Bool {
        if failServiceWorkerCalls > 0 {
            failServiceWorkerCalls -= 1
            return true
        }
        return false
    }
}

enum VisitorDataTestFixtures {
    // Protobuf field 1: "A1234567890" / "01234567890"; field 5: 1761000000.
    // Preserve the Base64 padding to cover raw HTTP-header encoding.
    static let letterVisitor = "CgtBMTIzNDU2Nzg5MCjA9NrHBg=="
    static let digitVisitor = "CgswMTIzNDU2Nzg5MCjA9NrHBg=="

    static func publicWebBootstrapResponse(for request: URLRequest) -> (HTTPURLResponse, Data)? {
        guard let url = request.url, url.host == "music.youtube.com", url.path == "/",
              request.httpMethod == "GET" else { return nil }
        let html = "<script>{\"INNERTUBE_API_KEY\":\"AIza\(String(repeating: "A", count: 35))\"," +
            "\"INNERTUBE_CONTEXT_CLIENT_VERSION\":\"1.20261021.01.00\"}</script>"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html"])!
        return (response, Data(html.utf8))
    }
}

/// Verify the actual generated protobuf rather than a Base64 prefix that
/// changes with the random visitor ID's first byte.
func assertFreshGeneratedVisitorData(
    _ value: String?, file: StaticString = #filePath, line: UInt = #line
) throws {
    let token = try XCTUnwrap(value, file: file, line: line)
    XCTAssertNotNil(token.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression),
                    file: file, line: line)
    let base64 = token.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let bytes = Array(try XCTUnwrap(Data(base64Encoded: padded), file: file, line: line))
    guard bytes.count >= 15 else {
        XCTFail("Generated visitor must contain an 11-byte ID and a timestamp", file: file, line: line)
        return
    }
    XCTAssertEqual(Array(bytes.prefix(2)), [0x0A, 0x0B], file: file, line: line)
    let identifier = try XCTUnwrap(String(bytes: bytes[2..<13], encoding: .utf8), file: file, line: line)
    XCTAssertNotNil(identifier.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression),
                    file: file, line: line)
    XCTAssertEqual(bytes[13], 0x28, file: file, line: line)
    var timestamp: UInt64 = 0
    var shift: UInt64 = 0
    var offset = 14
    var terminated = false
    while offset < bytes.count && shift <= 63 {
        let byte = bytes[offset]
        timestamp |= UInt64(byte & 0x7F) << shift
        offset += 1
        if byte & 0x80 == 0 {
            terminated = true
            break
        }
        shift += 7
    }
    XCTAssertTrue(terminated, file: file, line: line)
    XCTAssertEqual(offset, bytes.count, file: file, line: line)
    XCTAssertLessThan(abs(Date().timeIntervalSince1970 - Double(timestamp)), 60,
                      "Generated visitor must carry the current timestamp", file: file, line: line)
}
