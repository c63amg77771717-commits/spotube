#if DEBUG
import Foundation

/// Explicit UI-test transport for the real LRCLib repository. Never installed in Release.
final class LyricsCandidatePreviewHTTPFixture: URLProtocol {
    static let selectionKey = "song:demo_song_morning_light"
    static let legacySelectionKey = "arcadia|kevinmacleod|98"

    static func session(resetSelection: Bool) -> URLSession {
        if resetSelection {
            UserDefaults.standard.removeObject(forKey: "lyrics.selection." + selectionKey)
            UserDefaults.standard.removeObject(forKey: "lyrics.selection." + legacySelectionKey)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsCandidatePreviewHTTPFixture.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let query = components.queryItems ?? []
        let title = query.first { $0.name == "track_name" }?.value ?? "Arcadia"
        let artist = query.first { $0.name == "artist_name" }?.value ?? "Kevin MacLeod"
        let first: [String: Any] = ["id": 101, "trackName": title, "artistName": artist,
            "duration": 300.0, "plainLyrics": "Candidate UI first recording"]
        let second: [String: Any] = ["id": 102, "trackName": title, "artistName": artist,
            "duration": 360.0, "plainLyrics": "Candidate UI second recording"]
        let payload: Any
        if url.lastPathComponent == "search" { payload = [first, second] }
        else { payload = url.lastPathComponent == "102" ? second : first }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
