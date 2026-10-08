import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsPublicBoundaryTests: XCTestCase {
    func testClearingMockCannotEnablePublicLiveTransport() async throws {
        #if EVANTUBE_PUBLIC_CI
        AuthorizedSampleHTTPTransport.configureMock(nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://lrclib.net/api/search?track_name=SYNTHETIC_CANARY_TITLE")!)
            XCTFail("Unset mock must fail before any live request")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_CANARY_TITLE"))
        }
        XCTAssertTrue(AuthorizedSampleHTTPTransport.requests.isEmpty)
        #else
        throw XCTSkip("Public target compile condition required")
        #endif
    }

    func testExtraMetadataCannotReachMockOrLiveProvider() async throws {
        PublicBoundaryNeverNetworkMock.calls = 0
        AuthorizedSampleHTTPTransport.configureMock(PublicBoundaryNeverNetworkMock.self)
        defer { AuthorizedSampleHTTPTransport.configureMock(nil) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://lrclib.net/api/search?track_name=SYNTHETIC_CANARY_TITLE&duration=200")!)
            XCTFail("Unapproved metadata must fail before transport")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badURL)
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_CANARY_TITLE"))
        }
        XCTAssertEqual(PublicBoundaryNeverNetworkMock.calls, 0)
        XCTAssertTrue(AuthorizedSampleHTTPTransport.requests.isEmpty)
    }

    func testOnlyEntirelySyntheticFortyFixturesAreBundled() throws {
        let bundle = Bundle(for: Self.self)
        XCTAssertNil(bundle.url(forResource: "authorized_random_lyrics_sample", withExtension: "json"))
        for batch in [1,2] {
            let url = try XCTUnwrap(bundle.url(forResource: "fixed_lyrics_batch\(batch)", withExtension: "json"))
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(document["dataOrigin"] as? String, "entirelySynthetic")
            let samples = try XCTUnwrap(document["samples"] as? [[String: Any]])
            XCTAssertEqual(samples.count,20)
            for sample in samples {
                let title = try XCTUnwrap(sample["title"] as? String)
                XCTAssertTrue(title.hasPrefix("Synthetic ") || title.hasPrefix("合成歌曲"))
            }
        }
    }
}

private final class PublicBoundaryNeverNetworkMock: URLProtocol {
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
