import XCTest
@testable import LovelyMusic

final class PublicSourceRecoveryTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PublicRecoveryFixture.self]
        return URLSession(configuration: config)
    }
    func testTransientFailureRetriesOnceButPermanentHTTPIsNotRetried() async throws {
        await PublicRecoveryState.shared.reset()
        let session = session()
        defer { session.invalidateAndCancel() }
        for (path, expected, attempts) in [("recover", 200, 2), ("permanent", 400, 1), ("missing", 404, 1), ("unavailable", 503, 2)] {
            let (_, response) = try await PublicSourceRequest.data(for: URLRequest(url: URL(string: "https://fixture.test/\(path)")!), session: session, source: "Fixture")
            XCTAssertEqual(response.statusCode, expected)
            let count = await PublicRecoveryState.shared.count(path)
            XCTAssertEqual(count, attempts)
        }
    }
    func testRetryAfterIsRespectedWithinBoundAndLongWaitDoesNotRetry() {
        XCTAssertEqual(PublicSourceRequest.retryDelay(status: 429, retryAfter: "3"), 3)
        XCTAssertNil(PublicSourceRequest.retryDelay(status: 429, retryAfter: "60"))
        XCTAssertNil(PublicSourceRequest.retryDelay(status: 404, retryAfter: "0"))
        XCTAssertNil(PublicSourceRequest.retryDelay(status: 400, retryAfter: nil))
    }
    func testRealFeedCacheKeepsSourceAndDateAndNeverCrossesRegion() async throws {
        await PublicRecoveryState.shared.reset()
        let session = session()
        defer { session.invalidateAndCancel() }
        let suite = "EvanTube.chart.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let first = try await EvanTubeOnlineFeedService.chart(region: "TT", session: session, defaults: defaults, now: now)
        XCTAssertEqual(first.items.count, 20)
        XCTAssertNotNil(first.updatedAt, "The real Apple RFC2822 timestamp must be parsed")
        let cached = try await EvanTubeOnlineFeedService.chart(region: "TT", session: session, defaults: defaults, now: now.addingTimeInterval(60))
        XCTAssertTrue(cached.sourceName.contains("Apple Music · TT"))
        XCTAssertTrue(cached.sourceName.contains("快取"))
        XCTAssertTrue(cached.sourceName.contains("取得於"))
        XCTAssertEqual(cached.items.map(\.id), first.items.map(\.id))
        do {
            _ = try await EvanTubeOnlineFeedService.chart(region: "UU", session: session, defaults: defaults, now: now)
            XCTFail("A Taiwan-region cache cannot supply another selected region")
        } catch { XCTAssertTrue(error is PublicSourceError) }
        do {
            _ = try await EvanTubeOnlineFeedService.chart(region: "TT", session: session, defaults: defaults, now: now.addingTimeInterval(86401))
            XCTFail("Expired cache must not be called a current chart")
        } catch { XCTAssertTrue(error is PublicSourceError) }
    }
}

private actor PublicRecoveryState {
    static let shared = PublicRecoveryState()
    private var counts: [String: Int] = [:]
    func reset() { counts = [:] }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
    func next(_ key: String) -> Int { counts[key, default: 0] += 1; return counts[key]! }
}
private final class PublicRecoveryFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var task: Task<Void, Never>?
    override func startLoading() {
        task = Task {
            let url = request.url!
            let key = url.path
            let counter = await PublicRecoveryState.shared.next(url.host == "fixture.test" ? String(key.dropFirst()) : url.absoluteString)
            let realFeed = key.contains("/tt/") && url.host == "rss.marketingtools.apple.com" && counter == 1
            let status = realFeed || (key == "/recover" && counter == 2) ? 200 : (key == "/permanent" ? 400 : (key == "/missing" ? 404 : 503))
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if realFeed {
                let file = Bundle(for: PublicSourceRecoveryTests.self).url(forResource: "apple-tw20-live-20261004", withExtension: "json")!
                client?.urlProtocol(self, didLoad: try! Data(contentsOf: file))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { task?.cancel() }
}
