import Foundation

final class LrcLibService: LyricsRepositoryProtocol {
    private let baseURL = URL(string: "https://lrclib.net/api")!
    private let session: URLSession
    private let defaults: UserDefaults
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
        self.session = session ?? LyricsTransportPolicy.makeSession()
        self.defaults = defaults
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let metadata = LyricsCanonicalMetadata(context) else { return nil }
        var candidates: [LyricsCandidate] = []
        var failures: [LyricsSourceFailure] = []
        // The official GET /api/get/:track_id endpoint revalidates identity and content.
        if let saved = LyricsCandidateScorer.remembered(context, defaults: defaults), saved.providerID == .lrclib,
           let id = Int(saved.recordID), id > 0 {
            do {
                let response = try await request(endpoint: "get/" + String(id), items: [])
                if response.status == 200 {
                    let record = try decoder.decode(LrcLibResponse.self, from: response.data)
                    if let candidate = contextCandidate(record, context: context), candidate.id == saved,
                       LyricsCandidateScorer.score(candidate, metadata: metadata) != nil {
                        return LyricsCandidateScorer.choose([candidate], metadata: metadata, defaults: defaults)
                    }
                } else if response.status != 404 { throw PublicSourceError.http("LRCLib", response.status) }
            } catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
                break // Availability errors are not corrected by spelling variants.
            }
        }
        for query in LyricsQueryPlanner.queries(metadata) {
            try Task.checkCancellation()
            do {
                let records: [LrcLibResponse]
                if query.endpoint == "get" {
                    let response = try await get(pair: query.pair, duration: query.duration)
                    if response.status == 404 { continue }
                    guard response.status == 200 else { throw PublicSourceError.http("LRCLib", response.status) }
                    records = [try decoder.decode(LrcLibResponse.self, from: response.data)]
                } else {
                    records = try await search(pair: query.pair)
                }
                // Invalid identities are rejected by the common scorer, never before search fallback.
                candidates += records.prefix(30).compactMap { contextCandidate($0, context: context) }
                if let result = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) {
                    if query.endpoint == "search" || (!result.lines.isEmpty && result.isTimeSynced) { return result }
                }
            } catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        if let result = LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) { return result }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }

    private func contextCandidate(_ record: LrcLibResponse, context: LyricsLookupContext) -> LyricsCandidate? {
        guard let id = record.id, id > 0, let title = record.trackName, let artist = record.artistName,
              let lyrics = lyrics(record, duration: context.duration) else { return nil }
        return LyricsCandidate(id: .init(providerID: .lrclib, recordID: String(id)),
                               title: title, artist: artist, duration: record.duration, lyrics: lyrics, album: record.albumName)
    }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var pair = LyricsLookupMetadata.Pair(title: title, artist: artist)
        var hasExplicitPair = false
        if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard allowVideoCredits else { return nil }
            if let credit = LyricsLookupMetadata.cleaned(title: title, artist: artist, allowVideoCredits: true) {
                pair = credit
                hasExplicitPair = true
            } else {
                // Missing performer is a manual-choice flow, never an automatic match.
                // Ambiguous embedded credits must not be guessed into a bare song title.
                guard !title.contains(" - "), !title.contains("《"), !title.contains("【") else { return nil }
                let validDuration = LyricsMatchingPolicy.validDuration(duration)
                var matches = try await search(pair: pair)
                if matches.isEmpty, let simplified = LyricsLookupMetadata.simplifiedPair(pair) {
                    pair = simplified
                    matches = try await search(pair: pair)
                }
                let key = LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
                return choose(matches, pair: pair, duration: validDuration, key: key, missingArtist: true)
            }
        }
        let validDuration = LyricsMatchingPolicy.validDuration(duration)
        var response = try await get(pair: pair, duration: validDuration)
        if response.status == 404, validDuration != nil {
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404,
           let clean = LyricsLookupMetadata.cleaned(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) {
            pair = clean
            hasExplicitPair = true
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404,
           let chinese = LyricsLookupMetadata.chineseVideoPair(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) {
            pair = chinese
            hasExplicitPair = true
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404, allowVideoCredits,
           let simplified = LyricsLookupMetadata.simplifiedPair(pair) {
            pair = simplified
            response = try await get(pair: pair, duration: nil)
        }
        let key = LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        if response.status == 404 {
            guard hasExplicitPair else { return nil }
            let matches = try await search(pair: pair)
            return choose(matches, pair: pair, duration: validDuration, key: key)
        }
        guard response.status == 200 else { throw PublicSourceError.http("LRCLib", response.status) }
        let match = try decoder.decode(LrcLibResponse.self, from: response.data)
        guard identityMatches(match, pair: pair), let lyrics = lyrics(match, duration: validDuration) else { return nil }
        // A trusted identity with uncertain timing can still provide useful text.
        // Search the same explicit pair to expose multiple recordings to the user.
        if !lyrics.isTimeSynced || LyricsSelectionStore.selectedRecord(for: key, defaults: defaults) != nil, match.id != nil {
            var matches: [LrcLibResponse]
            var failures: [LyricsSourceFailure] = []
            do { matches = try await search(pair: pair) }
            catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                matches = [match]
                failures.append(LyricsSourceFailure(providerID: .lrclib, message: error.localizedDescription))
            }
            try Task.checkCancellation()
            return choose([match] + matches, pair: pair, duration: validDuration, key: key, failures: failures)
        }
        try Task.checkCancellation()
        if match.id != nil {
            return choose([match], pair: pair, duration: validDuration, key: key)
        }
        return lyrics
    }

    private func get(pair: LyricsLookupMetadata.Pair, duration: Int?) async throws -> (data: Data, status: Int) {
        var items = [URLQueryItem(name: "track_name", value: pair.title), URLQueryItem(name: "artist_name", value: pair.artist)]
        if let duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        return try await request(endpoint: "get", items: items)
    }

    private func search(pair: LyricsLookupMetadata.Pair) async throws -> [LrcLibResponse] {
        var items = [URLQueryItem(name: "track_name", value: pair.title)]
        if !pair.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: pair.artist)) }
        let result = try await request(endpoint: "search", items: items)
        if result.status == 404 { return [] }
        guard result.status == 200 else { throw PublicSourceError.http("LRCLib", result.status) }
        return try decoder.decode([LrcLibResponse].self, from: result.data)
    }

    private func request(endpoint: String, items: [URLQueryItem]) async throws -> (data: Data, status: Int) {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            return (Data(), 404)
        }
        components.queryItems = items
        guard let url = components.url else { return (Data(), 404) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib")
        try Task.checkCancellation()
        return (data, response.statusCode)
    }

    private func identityMatches(_ match: LrcLibResponse, pair: LyricsLookupMetadata.Pair, missingArtist: Bool = false) -> Bool {
        LyricsMatchingPolicy.identityMatches(title: match.trackName, artist: match.artistName,
                                             pair: pair, missingArtist: missingArtist)
    }

    private func choose(_ matches: [LrcLibResponse], pair: LyricsLookupMetadata.Pair,
                        duration: Int?, key: String, missingArtist: Bool = false,
                        failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var seen: Set<Int> = []
        let candidates = matches.prefix(31).compactMap { match -> LyricsCandidate? in
            guard identityMatches(match, pair: pair, missingArtist: missingArtist), let id = match.id, seen.insert(id).inserted,
                  let lyrics = lyrics(match, duration: duration) else { return nil }
            return LyricsCandidate(id: LyricsRecordID(providerID: .lrclib, recordID: String(id)),
                                   title: match.trackName!, artist: match.artistName!, duration: match.duration, lyrics: lyrics)
        }
        return LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: missingArtist,
                                           defaults: defaults, failures: failures)
    }

    private func lyrics(_ match: LrcLibResponse, duration: Int?) -> SyncedLyrics? {
        LyricsMatchingPolicy.lyrics(syncedLRC: match.syncedLyrics ?? "", plainText: match.plainLyrics,
                                   recordingDuration: match.duration, videoDuration: duration, provider: .lrclib)
    }
}

private struct LrcLibResponse: Codable {
    let id: Int?
    let trackName: String?
    let albumName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}
