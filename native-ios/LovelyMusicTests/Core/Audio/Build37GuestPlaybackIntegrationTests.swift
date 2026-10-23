import Foundation
import XCTest
@testable import LovelyMusic

/// Exercise the signed-out path through the production resolver and native
/// player. Every HTTP response is intercepted; media bytes are a bundled demo
/// recording, not a public-network or account-dependent fixture.
final class Build37GuestPlaybackIntegrationTests: XCTestCase {
    @MainActor
    func testDriveOnlyGuestPlaysPublicAudioWithoutSelectingUnusableIOSURL() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a")
        )
        let media = try Data(contentsOf: fixtureURL)
        GuestPlaybackIntegrationHTTP.prepare(media: media)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuestPlaybackIntegrationHTTP.self]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let suite = "build37-guest-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("drive-only-fixture", forKey: "evantube_drive_enabled_account")
        let api = InnerTubeAPI(session: session, userDefaults: defaults, cookie: nil)
        let repository = PlayerRepository(api: api)
        let engine = AudioEngine(audioTransferSession: session, progressiveStreaming: false)
        let trackID = "GUESTPLAY37"
        defer {
            engine.stop()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }
        engine.authCookieProvider = { nil }
        engine.streamURLResolver = { videoID in
            let descriptor = try await repository.resolveStreamDescriptor(
                videoId: videoID, quality: .medium, requestHeaders: [:]
            )
            return (url: descriptor.remoteURL.absoluteString,
                    contentLength: descriptor.contentLength)
        }
        engine.onStreamCandidateFailure = { id, url in
            repository.reportPlaybackCandidateFailure(videoId: id, streamURL: url)
        }
        engine.onStreamCandidateSuccess = { id, url in
            repository.reportPlaybackCandidateSuccess(videoId: id, streamURL: url)
        }
        var confirmed: [String] = []
        engine.onPlaybackConfirmed = { confirmed.append($0.id) }
        let song = Song(id: trackID, title: "Guest playback fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: nil,
                        thumbnailURL: nil)

        engine.play(song: song)
        for _ in 0..<500 {
            if engine.lastError != nil || (confirmed.contains(trackID) && engine.currentTime > 0.25) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(engine.lastError)
        XCTAssertTrue(confirmed.contains(trackID), "A resolved URL alone is not successful playback")
        XCTAssertGreaterThan(engine.currentTime, 0.25, "Native playback must actually advance")
        XCTAssertEqual(engine.currentTrack?.streamURL,
                       "https://guest-playback.example.test/public-audio.m4a")
        let requests = GuestPlaybackIntegrationHTTP.recordedRequests()
        XCTAssertFalse(requests.contains {
            $0.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "5"
        }, "An unusable guest IOS URL must not hide the public AAC source")
        XCTAssertTrue(requests.contains { $0.url?.path == "/public-audio.m4a" })
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertFalse(cookie.contains("SAPISID="))
            XCTAssertFalse(cookie.contains("SID="))
        }
        let context = await api.playerSessionContext()
        XCTAssertFalse(context.isAuthenticated)
    }
}

private final class GuestPlaybackIntegrationHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var media = Data()
    private static var requests: [URLRequest] = []
    private static var visitor = ""

    static func prepare(media: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.media = media
        requests = []
        visitor = VisitorDataGenerator.generate()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests.append(request)
        let media = Self.media
        let visitor = Self.visitor
        Self.lock.unlock()
        var status = 200
        var contentType = "application/json"
        let payload: Data
        if url.host == "www.youtube.com", ["/tv", "/watch"].contains(url.path) {
            contentType = "text/html"
            payload = Data("<script>var ytInitialData={\"visitorData\":\"\(visitor)\"};</script>".utf8)
        } else if url.host == "www.youtube.com", url.path == "/youtubei/v1/player" {
            let isGuestIOS = request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "5"
            let name = isGuestIOS ? "unusable-ios.m4a" : "public-audio.m4a"
            payload = try! JSONSerialization.data(withJSONObject: [
                "playabilityStatus": ["status": "OK"],
                "streamingData": ["adaptiveFormats": [[
                    "itag": 140,
                    "url": "https://guest-playback.example.test/\(name)",
                    "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                    "bitrate": 128_000,
                    "contentLength": String(media.count),
                ]]],
            ])
        } else if url.host == "guest-playback.example.test", url.path == "/public-audio.m4a" {
            // A complete resource with independently declared length is valid
            // even when this fixture intentionally ignores the Range header.
            contentType = "audio/mp4"
            payload = media
        } else if url.host == "guest-playback.example.test", url.path == "/unusable-ios.m4a" {
            status = 403
            payload = Data("unusable IOS fixture".utf8)
        } else {
            status = 404
            payload = Data()
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType,
                                                      "Content-Length": String(payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
