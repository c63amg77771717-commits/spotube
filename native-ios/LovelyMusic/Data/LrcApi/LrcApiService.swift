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
        try await lookup(context: context).legacyValue()
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        let timings = LyricsLookupStageTimings()
        defer { timings.record(context: context, provider: .lrcapi) }
        try Task.checkCancellation()
        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .lookup, reason: .originalMetadata,
            title: context.title, artist: context.artist, duration: context.duration.map { Double($0) }))
        guard let metadata = timings.measure("metadataAndHypotheses", { LyricsCanonicalMetadata(context) }) else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .result, reason: .metadataRejected))
            return .metadataRejected(provider: .lrcapi)
        }
        timings.measure("hypothesisDiagnostics", { LyricsLookupDiagnostics.shared.recordHypotheses(metadata, provider: .lrcapi) })
        var candidates: [LyricsCandidate] = []
        var evidence: [LyricsCandidateEvidence] = []
        let remembered = LyricsCandidateScorer.remembered(context, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var received = 0
        var successfulResponses = 0
        func report(_ lyrics: SyncedLyrics?) -> LyricsLookupReport {
            .provider(.lrcapi, lyrics: lyrics, received: received,
                      successfulResponses: successfulResponses, failures: failures, contentCandidates: evidence.filter { $0.contentLineCount > 0 }.count,
                      rejectionReasons: evidence.reduce(into: [String: Int]()) { counts, record in
                          if record.identity == "rejected" { counts[record.reason ?? "identityMismatch", default: 0] += 1 }
                      }, evaluatedCandidates: evidence, stageTimings: timings.snapshot())
        }
        // jsonapi has no verified record-ID route. Revalidate saved IDs in bounded metadata responses.
        let pairs = timings.measure("queryPlanning", { LyricsQueryPlanner.secondaryPairs(metadata) })
        for pair in pairs {
            try Task.checkCancellation()
            do {
                let records = try await request(pair: pair, diagnosticContext: context, timings: timings)
                try Task.checkCancellation()
                LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi,
                    phase: .response, count: records.count))
                successfulResponses += 1; received += min(records.count, 30)
                candidates += timings.measure("candidateContentAndEvidence") { records.prefix(30).compactMap { record -> LyricsCandidate? in
                    guard !record.id.isEmpty, record.id.count <= 256, let title = record.title, let artist = record.artist else {
                        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .candidateDropped, reason: .missingMetadata))
                        evidence.append(.init(provider: .lrcapi, recordID: record.id, title: record.title, artist: record.artist,
                            album: record.album, duration: record.duration, metadata: metadata, discardedReason: .missingMetadata,
                            queryEndpoint: "jsonapi", queryTitle: pair.title, queryArtist: pair.artist))
                        return nil
                    }
                    guard let lyrics = LyricsMatchingPolicy.lyrics(syncedLRC: record.lrc ?? record.lyrics ?? "",
                        plainText: record.lyrics, recordingDuration: record.duration, videoDuration: context.duration, provider: .lrcapi) else {
                        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .candidateDropped,
                            reason: .emptyContent, title: title, artist: artist, recordID: record.id))
                        evidence.append(.init(provider: .lrcapi, recordID: record.id, title: title, artist: artist,
                            album: record.album, duration: record.duration, metadata: metadata, discardedReason: .emptyContent,
                            queryEndpoint: "jsonapi", queryTitle: pair.title, queryArtist: pair.artist))
                        return nil
                    }
                    let candidate = LyricsCandidate(id: .init(providerID: .lrcapi, recordID: record.id),
                                           title: title, artist: artist, duration: record.duration, lyrics: lyrics, album: record.album)
                    evidence.append(.init(provider: .lrcapi, recordID: record.id, title: title, artist: artist,
                        album: record.album, duration: record.duration, metadata: metadata, candidate: candidate, remembered: remembered,
                        queryEndpoint: "jsonapi", queryTitle: pair.title, queryArtist: pair.artist))
                    return candidate
                } }
                if let result = timings.measure("selectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) }) {
                    if !result.lines.isEmpty && result.isTimeSynced && !metadata.requiresManualIdentityConfirmation { return report(result) }
                }
            } catch {
                LyricsLookupDiagnostics.shared.recordFailure(context: context, provider: .lrcapi, error: error)
                try LyricsMatchingPolicy.checkCancellation(error)
                failures += LyricsSourceFailure.from(error, providerID: .lrcapi)
                break
            }
        }
        if let result = timings.measure("selectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) }) { return report(result) }
        try Task.checkCancellation()
        return report(nil)
    }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try await lookup(context: .init(title: title, artist: artist, duration: duration,
                                       hasYouTubeOrigin: allowVideoCredits)).legacyValue()
    }

    private func request(pair: LyricsLookupMetadata.Pair, diagnosticContext: LyricsLookupContext? = nil, timings: LyricsLookupStageTimings? = nil) async throws -> [LrcApiRecord] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "title", value: pair.title)]
        if !pair.artist.isEmpty { query.append(URLQueryItem(name: "artist", value: pair.artist)) }
        components.queryItems = query
        guard let url = components.url else { throw PublicSourceError.invalidResponse("LrcApi") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .query,
                endpoint: "jsonapi", title: pair.title, artist: pair.artist))
        }
        let observer: ((PublicSourceRequest.TransportEvidence) -> Void)? = diagnosticContext.map { context in
            { evidence in
                LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .transportAttempt,
                    endpoint: "jsonapi", httpStatus: evidence.httpStatus, cacheSource: evidence.fetchSource,
                    attempt: evidence.attempt, transportErrorCode: evidence.transportErrorCode,
                    latencyMilliseconds: evidence.latencyMilliseconds))
            }
        }
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session,
                                                                source: "LrcApi", retryTransient: retryTransient, diagnostics: observer)
        try Task.checkCancellation()
        if let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .response,
                reason: response.statusCode == 200 ? nil : .http, endpoint: "jsonapi", httpStatus: response.statusCode))
        }
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 200 else { throw PublicSourceError.http("LrcApi", response.statusCode) }
        guard data.count <= 2 * 1024 * 1024 else { throw PublicSourceError.invalidResponse("LrcApi") }
        let records: [LrcApiRecord]
        if let timings { records = try timings.measure("decoding", { try JSONDecoder().decode([LrcApiRecord].self, from: data) }) }
        else { records = try JSONDecoder().decode([LrcApiRecord].self, from: data) }
        if records.isEmpty, let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi,
                phase: .providerEmpty, reason: .providerEmpty, endpoint: "jsonapi", httpStatus: 200, count: 0))
        }
        return records
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
