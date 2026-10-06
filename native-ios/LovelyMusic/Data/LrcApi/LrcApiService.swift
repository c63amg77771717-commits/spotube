import Foundation

enum LyricsSecondarySettings {
    static let enabledKey = "lyrics.secondary.lrcapi.enabled"
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Official public /jsonapi endpoint. No cookies, credentials, disk cache or batch lookup.
final class LrcApiService: LyricsRepositoryProtocol {
    private let session: URLSession
    private let defaults: UserDefaults
    private let timeout: TimeInterval
    private let retryTransient: Bool
    private let endpoint = URL(string: "https://api.lrc.cx/jsonapi")!

    init(session: URLSession? = nil, defaults: UserDefaults = .standard,
         timeout: TimeInterval = 8, retryTransient: Bool = true) {
        self.session = session ?? LyricsTransportPolicy.makeSession()
        self.defaults = defaults
        self.timeout = timeout.isFinite ? min(max(timeout, 0.1), 15) : 8
        self.retryTransient = retryTransient
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let metadata = LyricsCanonicalMetadata(context) else { return nil }
        var candidates: [LyricsCandidate] = []
        var failures: [LyricsSourceFailure] = []
        // jsonapi has no verified record-ID route. Revalidate saved IDs in bounded metadata responses.
        for pair in LyricsQueryPlanner.secondaryPairs(metadata) {
            try Task.checkCancellation()
            do {
                let records = try await request(pair: pair)
                try Task.checkCancellation()
                candidates += records.prefix(30).compactMap { record -> LyricsCandidate? in
                    guard !record.id.isEmpty, record.id.count <= 256, let title = record.title, let artist = record.artist,
                          let lyrics = LyricsMatchingPolicy.lyrics(syncedLRC: record.lrc ?? record.lyrics ?? "",
                              plainText: record.lyrics, recordingDuration: record.duration,
                              videoDuration: context.duration, provider: .lrcapi) else { return nil }
                    return LyricsCandidate(id: .init(providerID: .lrcapi, recordID: record.id),
                                           title: title, artist: artist, duration: record.duration, lyrics: lyrics, album: record.album)
                }
                if let result = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) {
                    return result
                }
            } catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrcapi, message: error.localizedDescription))
                break
            }
        }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let pair = LyricsLookupMetadata.secondaryPair(title: title, artist: artist,
                                                           allowVideoCredits: allowVideoCredits) else { return nil }
        let missingArtist = pair.artist.isEmpty
        let key = LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        var pairs = [pair]
        if let simplified = LyricsLookupMetadata.simplifiedPair(pair) { pairs.append(simplified) }
        // At most two spelling queries, each with at most one transient retry.
        for lookup in pairs.prefix(2) {
            try Task.checkCancellation()
            let records = try await request(pair: lookup)
            try Task.checkCancellation()
            var seen = Set<String>()
            let candidates = records.prefix(30).compactMap { record -> LyricsCandidate? in
                guard !record.id.isEmpty, seen.insert(record.id).inserted,
                      LyricsMatchingPolicy.identityMatches(title: record.title, artist: record.artist,
                                                           pair: lookup, missingArtist: missingArtist),
                      let lyrics = LyricsMatchingPolicy.lyrics(syncedLRC: record.lrc ?? record.lyrics ?? "",
                          plainText: record.lyrics, recordingDuration: record.duration,
                          videoDuration: duration, provider: .lrcapi) else { return nil }
                return LyricsCandidate(id: LyricsRecordID(providerID: .lrcapi, recordID: record.id),
                                       title: record.title!, artist: record.artist!, duration: record.duration, lyrics: lyrics)
            }
            if let result = LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: missingArtist,
                                                       defaults: defaults) { return result }
        }
        return nil
    }

    private func request(pair: LyricsLookupMetadata.Pair) async throws -> [LrcApiRecord] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "title", value: pair.title)]
        if !pair.artist.isEmpty { query.append(URLQueryItem(name: "artist", value: pair.artist)) }
        components.queryItems = query
        guard let url = components.url else { throw PublicSourceError.invalidResponse("LrcApi") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session,
                                                                source: "LrcApi", retryTransient: retryTransient)
        try Task.checkCancellation()
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 200 else { throw PublicSourceError.http("LrcApi", response.statusCode) }
        guard data.count <= 2 * 1024 * 1024 else { throw PublicSourceError.invalidResponse("LrcApi") }
        return try JSONDecoder().decode([LrcApiRecord].self, from: data)
    }
}

private struct LrcApiRecord: Decodable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let duration: Double?
    let lyrics: String?
    let lrc: String?

    enum CodingKeys: String, CodingKey { case id, title, artist, album, duration, lyrics, lrc }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? c.decode(String.self, forKey: .id) { id = string }
        else if let number = try? c.decode(Int.self, forKey: .id) { id = String(number) }
        else { id = "" }
        title = try c.decodeIfPresent(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        lrc = try c.decodeIfPresent(String.self, forKey: .lrc)
    }
}

/// Shared by both lyric adapters; lyric content is not written to URLCache or cookies.
enum LyricsTransportPolicy {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }
}
