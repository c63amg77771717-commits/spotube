#if DEBUG
import Foundation

/// Review-mode-only transport for actual primary/composite/secondary UI wiring.
final class LrcApiPreviewHTTPFixture: URLProtocol {
    static func session(resetSelection: Bool) -> URLSession {
        if resetSelection {
            UserDefaults.standard.removeObject(forKey: "lyrics.selection." + LyricsCandidatePreviewHTTPFixture.selectionKey)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [LrcApiPreviewHTTPFixture.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let primary = url.host == "lrclib.net"
        let title = query.first { $0.name == (primary ? "track_name" : "title") }?.value ?? "Arcadia"
        let artist = query.first { $0.name == (primary ? "artist_name" : "artist") }?.value ?? "Kevin MacLeod"
        let payload: Any
        if primary {
            let one: [String: Any] = ["id": 101, "trackName": title, "artistName": artist,
                                     "duration": 300.0, "plainLyrics": "LRCLib UI recording"]
            payload = url.lastPathComponent == "search" ? [one] : one
        } else {
            payload = [
                ["id": "101", "title": title, "artist": artist, "duration": 98.0,
                 "lrc": "[00:01.00]LrcApi UI first recording"],
                ["id": "102", "title": title, "artist": artist, "duration": 360.0,
                 "lrc": "[!text]LrcApi UI second recording"]
            ] as [[String: Any]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
/// Default Debug Review response for layout tests. Explicit lyric fixtures above still use real adapters.
struct ReviewLyricsFixtureRepository: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        return nil
    }
}
#endif
