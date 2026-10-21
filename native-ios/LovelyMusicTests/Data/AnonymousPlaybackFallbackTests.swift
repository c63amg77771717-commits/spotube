import Foundation
import XCTest
@testable import LovelyMusic

/// Google Drive OAuth and the YouTube player are independent. A clean, keyless
/// installation tries public audio before the guest iOS compatibility source.
/// No live login, network request, credential, or Drive mutation is used here.
final class AnonymousPlaybackFallbackTests: XCTestCase {
    private static let fakeKey = "AIza" + String(repeating: "A", count: 35)
    private static let fakeVersion = "1.20261021.01.00"

    func testSignedOutWebPlayerBootstrapsWithoutEmbeddedKey() async throws {
        AnonymousPlaybackHTTPFixture.reset()
        let (api, session, defaults, name) = try makeAPI()
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
        }
        // The Drive setting is intentionally unrelated to the playback key.
        defaults.set("drive-only-test-account", forKey: "evantube_drive_enabled_account")

        let data = try await api.player(client: .webRemix, videoId: "67Pylw3Kukc")
        XCTAssertFalse(data.isEmpty)
        let request = try XCTUnwrap(AnonymousPlaybackHTTPFixture.publicPlayerRequest())
        XCTAssertEqual(request.url?.host, "music.youtube.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"),
                       Self.fakeVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookieHeader.contains("SAPISID="))
        XCTAssertFalse(cookieHeader.contains("SID="))
        let key = URLComponents(url: try XCTUnwrap(request.url),
                                resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value
        XCTAssertEqual(key, Self.fakeKey)
    }

    func testGuestShortVisionOSWindowResolvesFullPublicAACBeforeIOS() async throws {
        AnonymousPlaybackHTTPFixture.reset()
        let (api, session, defaults, name) = try makeAPI()
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
        }
        defaults.set("drive-only-test-account", forKey: "evantube_drive_enabled_account")
        let context = await api.playerSessionContext()
        XCTAssertFalse(context.isAuthenticated)
        let result = try await PlayerRepository(api: api).resolveStreamDescriptor(
            videoId: "67Pylw3Kukc", quality: .medium, requestHeaders: [:]
        )
        XCTAssertEqual(result.remoteURL.absoluteString,
                       "https://cdn.example.test/full-song.m4a")
        XCTAssertEqual(result.mimeType, "audio/mp4")
        XCTAssertEqual(result.contentLength, 3_000_000)
        XCTAssertNotNil(AnonymousPlaybackHTTPFixture.publicPlayerRequest(),
                        "No signed-in YouTube session should be needed for a public AAC source")
        XCTAssertNil(AnonymousPlaybackHTTPFixture.sessionPlayerRequest(),
                     "A guest iOS response must not hide the full public AAC source")
    }

    func testGuestHTTPFailureFromVisionOSStillTriesPublicWeb() async throws {
        AnonymousPlaybackHTTPFixture.reset(visionFailure: true)
        let (api, session, defaults, name) = try makeAPI()
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
        }
        let result = try await PlayerRepository(api: api).resolveStreamDescriptor(
            videoId: "67Pylw3Kukc", quality: .medium, requestHeaders: [:]
        )
        XCTAssertEqual(result.remoteURL.absoluteString,
                       "https://cdn.example.test/full-song.m4a")
        XCTAssertNotNil(AnonymousPlaybackHTTPFixture.publicPlayerRequest())
    }

    func testHLSRemainsFallbackIfPublicWebHasNoDirectAAC() async throws {
        AnonymousPlaybackHTTPFixture.reset(publicAAC: false)
        let (api, session, defaults, name) = try makeAPI()
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
        }
        let result = try await PlayerRepository(api: api).resolveStreamDescriptor(
            videoId: "67Pylw3Kukc", quality: .medium, requestHeaders: [:]
        )
        XCTAssertEqual(result.mimeType, "application/x-mpegURL")
        XCTAssertEqual(result.remoteURL.absoluteString,
                       "https://cdn.example.test/manifest/hls/short-window.m3u8")
        XCTAssertNotNil(AnonymousPlaybackHTTPFixture.publicPlayerRequest())
        // AudioEngine's existing 69-second guard remains responsible for
        // rejecting this incomplete candidate against a longer song.
        XCTAssertTrue(AudioTrackDurationIntegrity.isIncomplete(
            measuredSeconds: 69, expectedSeconds: 240))
    }

    private func makeAPI() throws -> (InnerTubeAPI, URLSession, UserDefaults, String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnonymousPlaybackHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let suite = "anonymous-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let api = InnerTubeAPI(session: session, userDefaults: defaults, cookie: nil)
        return (api, session, defaults, suite)
    }
}

private final class AnonymousPlaybackHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var lastWebRequest: URLRequest?
    private static var lastIOSRequest: URLRequest?
    private static var visionFailure = false
    private static var publicAAC = true

    static func reset(visionFailure: Bool = false, publicAAC: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        lastWebRequest = nil
        lastIOSRequest = nil
        self.visionFailure = visionFailure
        self.publicAAC = publicAAC
    }

    static func publicPlayerRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastWebRequest
    }

    static func sessionPlayerRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastIOSRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "music.youtube.com" || host == "www.youtube.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        var status = 200
        var mime = "application/json"
        var payload = "{}"
        if url.host == "music.youtube.com", path == "/" {
            mime = "text/html"
            payload = "<script>ytcfg.set({\"INNERTUBE_API_KEY\":\"" +
                "AIza\(String(repeating: "A", count: 35))" +
                "\",\"INNERTUBE_CONTEXT_CLIENT_VERSION\":\"1.20261021.01.00\"});</script>"
        } else if url.host == "music.youtube.com", path == "/youtubei/v1/player" {
            Self.lock.lock()
            Self.lastWebRequest = request
            let validAAC = Self.publicAAC
            Self.lock.unlock()
            payload = validAAC ?
                """
                {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{
                  "itag":140,"url":"https://cdn.example.test/full-song.m4a",
                  "mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"",
                  "bitrate":128000,"contentLength":"3000000","approxDurationMs":"240000"
                }]}}
                """ :
                """
                {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[]}}
                """
        } else if url.host == "www.youtube.com", path == "/watch" {
            mime = "text/html"
            payload = "<script>ytcfg.set({\"visitorData\":\"CgtWATCH_VISITOR_TOKEN_BUILD37\"});</script>"
        } else if url.host == "www.youtube.com", path == "/tv" {
            mime = "text/html"
            payload = "<script>ytcfg.set({\"visitorData\":\"CgtTVVZJU0lUT1JfVE9LRU5fMzc=\"});</script>"
        } else if url.host == "www.youtube.com", path == "/youtubei/v1/player" {
            let clientName = request.value(forHTTPHeaderField: "X-Youtube-Client-Name") ?? ""
            if clientName == "101" {
                Self.lock.lock()
                let fail = Self.visionFailure
                Self.lock.unlock()
                if fail {
                    status = 400
                    payload = "{\"error\":\"visionos temporarily unavailable\"}"
                } else {
                    payload = """
                    {"playabilityStatus":{"status":"OK"},"streamingData":{
                      "hlsManifestUrl":"https://cdn.example.test/manifest/hls/short-window.m3u8",
                      "adaptiveFormats":[]}}
                    """
                }
            } else {
                Self.lock.lock()
                Self.lastIOSRequest = request
                Self.lock.unlock()
                status = 400
                payload = "{\"error\":\"guest IOS session unavailable\"}"
            }
        } else {
            status = 404
        }

        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
