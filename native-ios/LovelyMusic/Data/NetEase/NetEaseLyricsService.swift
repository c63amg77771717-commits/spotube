import Foundation

/// NetEase Cloud Music public search + LRC endpoints (no login). Strong on
/// Chinese songs. Results go through the same identity scoring as LRCLIB, and
/// a timeline is only trusted when the recording length matches the video.
final class NetEaseLyricsService: LyricsRepositoryProtocol {
    private let session: URLSession
    private let defaults: UserDefaults
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    // Bounds network use: two searches, lyrics for at most three plausible songs.
    private static let maxQueries = 2
    private static let maxLyricFetches = 3

    init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
        self.session = session ?? LyricsTransportPolicy.makeSession()
        self.defaults = defaults
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try await lookup(context: context).legacyValue()
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(context: .init(title: title, artist: artist, duration: duration))
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        try Task.checkCancellation()
        guard let metadata = LyricsCanonicalMetadata(context) else { return .metadataRejected(provider: .netease) }
        var candidates: [LyricsCandidate] = []
        var fetched = Set<Int>()
        var received = 0
        var successful = 0
        var failures: [LyricsSourceFailure] = []
        for pair in LyricsQueryPlanner.secondaryPairs(metadata).prefix(Self.maxQueries) {
            do {
                let songs = try await search([pair.title, pair.artist].filter { !$0.isEmpty }.joined(separator: " "))
                successful += 1
                received += songs.count
                for song in songs where !fetched.contains(song.id) && fetched.count < Self.maxLyricFetches {
                    // Score identity first (title/artist/version) so only plausible songs cost a lyric request.
                    let probe = song.candidate(lyrics: SyncedLyrics(lines: [LyricLine(time: 0, text: "-")], source: "NetEase",
                                                                    isTimeSynced: false, providerID: .netease))
                    guard LyricsCandidateScorer.decision(probe, metadata: metadata).kind != .rejected else { continue }
                    fetched.insert(song.id)
                    guard let lrc = try await lyric(song.id),
                          let lyrics = LyricsMatchingPolicy.lyrics(syncedLRC: lrc, plainText: nil,
                              recordingDuration: song.duration, videoDuration: context.duration, provider: .netease)
                    else { continue }
                    candidates.append(song.candidate(lyrics: lyrics))
                }
            } catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                failures += LyricsSourceFailure.from(error, providerID: .netease)
                break
            }
        }
        try Task.checkCancellation()
        let lyrics = candidates.isEmpty ? nil
            : LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures)
        return .provider(.netease, lyrics: lyrics, received: received, successfulResponses: successful,
                         failures: failures, contentCandidates: candidates.count)
    }

    struct Song: Equatable {
        let id: Int
        let title: String
        let artist: String
        let album: String?
        let duration: Double?

        func candidate(lyrics: SyncedLyrics) -> LyricsCandidate {
            LyricsCandidate(id: .init(providerID: .netease, recordID: String(id)), title: title, artist: artist,
                            duration: duration, lyrics: lyrics, album: album)
        }
    }

    static func songs(from data: Data) throws -> [Song] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let songs = ((object as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.prefix(10).compactMap { song in
            guard let id = song["id"] as? Int, let title = song["name"] as? String else { return nil }
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard !artists.isEmpty else { return nil }
            let milliseconds = (song["duration"] as? Double) ?? (song["duration"] as? Int).map(Double.init)
            return Song(id: id, title: title, artist: artists.joined(separator: "/"),
                        album: (song["album"] as? [String: Any])?["name"] as? String,
                        duration: milliseconds.map { $0 / 1000 })
        }
    }

    static func lrc(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["lrc"] as? [String: Any])?["lyric"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    private func search(_ query: String) async throws -> [Song] {
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [.init(name: "s", value: query), .init(name: "type", value: "1"),
                                 .init(name: "limit", value: "10")]
        return try Self.songs(from: try await get(components.url!))
    }

    private func lyric(_ id: Int) async throws -> String? {
        try Self.lrc(from: try await get(URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1")!))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw PublicSourceError.http("NetEase", status) }
        guard data.count <= 2 * 1024 * 1024 else { throw PublicSourceError.invalidResponse("NetEase") }
        return data
    }
}
