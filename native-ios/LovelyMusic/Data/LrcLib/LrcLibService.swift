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
        try await lookup(context: context).legacyValue()
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        let timings = LyricsLookupStageTimings()
        defer { timings.record(context: context, provider: .lrclib) }
        try Task.checkCancellation()
        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .lookup, reason: .originalMetadata,
            title: context.title, artist: context.artist, duration: context.duration.map { Double($0) }))
        guard let metadata = timings.measure("metadataAndHypotheses", { LyricsCanonicalMetadata(context) }) else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .result, reason: .metadataRejected))
            return .metadataRejected(provider: .lrclib)
        }
        timings.measure("hypothesisDiagnostics", { LyricsLookupDiagnostics.shared.recordHypotheses(metadata, provider: .lrclib) })
        let scoringSession = LyricsLookupScoringSession()
        var candidates: [LyricsCandidate] = []
        var evidence: [LyricsCandidateEvidence] = []
        let remembered = LyricsCandidateScorer.remembered(context, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var received = 0
        var successfulResponses = 0
        func report(_ lyrics: SyncedLyrics?) -> LyricsLookupReport {
            .provider(.lrclib, lyrics: lyrics, received: received,
                      successfulResponses: successfulResponses, failures: failures, contentCandidates: evidence.filter { $0.contentLineCount > 0 }.count,
                      rejectionReasons: evidence.reduce(into: [String: Int]()) { counts, record in
                          if record.identity == "rejected" { counts[record.reason ?? "identityMismatch", default: 0] += 1 }
                      }, evaluatedCandidates: evidence, stageTimings: timings.snapshot())
        }
        // The official GET /api/get/:track_id endpoint revalidates identity and content.
        if let saved = LyricsCandidateScorer.remembered(context, defaults: defaults), saved.providerID == .lrclib,
           let id = Int(saved.recordID), id > 0 {
            do {
                let response = try await request(endpoint: "get/" + String(id), items: [], diagnosticContext: context)
                if response.status == 404 { successfulResponses += 1 }
                if response.status == 200 {
                    let record = try timings.measure("decoding", { try decoder.decode(LrcLibResponse.self, from: response.data) })
                    received += 1; successfulResponses += 1
                    let candidate = contextCandidate(record, context: context)
                    evidence.append(.init(provider: .lrclib, recordID: record.id.map { String($0) }, title: record.trackName,
                        artist: record.artistName, album: record.albumName, duration: record.duration, metadata: metadata,
                        candidate: candidate,
                        discardedReason: candidate == nil ? (record.instrumental == true ? .instrumental :
                            record.id.map { $0 > 0 } != true || record.trackName == nil || record.artistName == nil ? .missingMetadata : .emptyContent)
                            : candidate?.id != saved ? .identityMismatch : nil,
                        remembered: remembered, queryEndpoint: "get/" + String(id), scoringSession: scoringSession))
                    if let candidate, candidate.id == saved {
                        candidates.append(candidate)
                        let identity = scoringSession.decision(candidate, metadata: metadata, remembered: remembered)
                        // Manual/weak/untimed remembered records remain available but never suppress fallback.
                        if candidate.id == saved, identity.kind == .confirmed, candidate.lyrics.isTimeSynced {
                            let result = timings.measure("selectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, scoringSession: scoringSession) })
                            try Task.checkCancellation()
                            return report(result)
                        }
                        let timingReason: LyricsLookupDiagnostics.Reason?
                        switch candidate.lyrics.timingState {
                        case .structurallyCompatible: timingReason = nil
                        case .plainOnly: timingReason = .plainOnly
                        case .timingUnknown: timingReason = .timingUnknown
                        case .durationMismatch: timingReason = .durationMismatch
                        case .invalidTimestamp: timingReason = .invalidTimestamp
                        case .unsupportedTiming: timingReason = .unsupportedTiming
                        }
                        LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib,
                            phase: identity.kind == .rejected ? .candidateDropped : .candidateAccepted,
                            reason: identity.reason ?? timingReason,
                            title: candidate.title, artist: candidate.artist, recordID: candidate.recordID,
                            score: identity.score, hypothesisID: identity.hypothesisID))
                    }
                } else if response.status != 404 { throw PublicSourceError.http("LRCLib", response.status) }
            } catch {
                LyricsLookupDiagnostics.shared.recordFailure(context: context, provider: .lrclib, error: error)
                try LyricsMatchingPolicy.checkCancellation(error)
                failures += LyricsSourceFailure.from(error, providerID: .lrclib)
            }
        }
        let queries = timings.measure("queryPlanning", { LyricsQueryPlanner.queries(metadata) })
        for query in queries {
            try Task.checkCancellation()
            do {
                let records: [LrcLibResponse]
                if query.endpoint == "get" {
                    let response = try await get(pair: query.pair, duration: query.duration, diagnosticContext: context)
                    if response.status == 404 { successfulResponses += 1; continue }
                    guard response.status == 200 else { throw PublicSourceError.http("LRCLib", response.status) }
                    records = [try timings.measure("decoding", { try decoder.decode(LrcLibResponse.self, from: response.data) })]
                } else {
                    records = try await search(pair: query.pair, diagnosticContext: context, timings: timings)
                }
                LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib,
                    phase: .response, count: records.count))
                successfulResponses += 1; received += min(records.count, 30)
                // Invalid identities are rejected by the common scorer, never before search fallback.
                timings.measure("candidateContentAndEvidence") {
                for record in records.prefix(30) {
                    let candidate = contextCandidate(record, context: context)
                    evidence.append(.init(provider: .lrclib, recordID: record.id.map { String($0) }, title: record.trackName,
                        artist: record.artistName, album: record.albumName, duration: record.duration, metadata: metadata,
                        candidate: candidate, discardedReason: candidate == nil ? (record.instrumental == true ? .instrumental :
                            record.id.map { $0 > 0 } != true || record.trackName == nil || record.artistName == nil ? .missingMetadata : .emptyContent) : nil,
                        remembered: remembered, queryEndpoint: query.endpoint,
                        queryTitle: query.pair.title, queryArtist: query.pair.artist, scoringSession: scoringSession))
                    if let candidate { candidates.append(candidate) }
                }
                }
                if let result = timings.measure("selectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures, scoringSession: scoringSession) }) {
                    try Task.checkCancellation()
                    if !result.lines.isEmpty && result.isTimeSynced && !metadata.requiresManualIdentityConfirmation { return report(result) }
                }
            } catch {
                LyricsLookupDiagnostics.shared.recordFailure(context: context, provider: .lrclib, error: error)
                try LyricsMatchingPolicy.checkCancellation(error)
                failures += LyricsSourceFailure.from(error, providerID: .lrclib)
                break // Availability errors are not corrected by spelling variants.
            }
        }
        try Task.checkCancellation()
        if let result = timings.measure("selectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures, scoringSession: scoringSession) }) { try Task.checkCancellation(); return report(result) }
        try Task.checkCancellation()
        return report(nil)
    }

    private func contextCandidate(_ record: LrcLibResponse, context: LyricsLookupContext) -> LyricsCandidate? {
        guard let id = record.id, id > 0, let title = record.trackName, let artist = record.artistName else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .candidateDropped, reason: .missingMetadata))
            return nil
        }
        guard record.instrumental != true, let lyrics = lyrics(record, duration: context.duration) else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .candidateDropped,
                reason: record.instrumental == true ? .instrumental : .emptyContent, title: title, artist: artist, recordID: String(id)))
            return nil
        }
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
        // Legacy video calls supply uploader text without performer provenance.
        // Context-based lookup keeps the default verified-performer constraint.
        if response.status == 404,
           let clean = LyricsLookupMetadata.cleaned(title: pair.title, artist: pair.artist,
               allowVideoCredits: allowVideoCredits, allowArtistReplacement: allowVideoCredits) {
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

    private func get(pair: LyricsLookupMetadata.Pair, duration: Int?, diagnosticContext: LyricsLookupContext? = nil) async throws -> (data: Data, status: Int) {
        var items = [URLQueryItem(name: "track_name", value: pair.title), URLQueryItem(name: "artist_name", value: pair.artist)]
        if let duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        return try await request(endpoint: "get", items: items, diagnosticContext: diagnosticContext)
    }

    private func search(pair: LyricsLookupMetadata.Pair, diagnosticContext: LyricsLookupContext? = nil, timings: LyricsLookupStageTimings? = nil) async throws -> [LrcLibResponse] {
        var items = [URLQueryItem(name: "track_name", value: pair.title)]
        if !pair.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: pair.artist)) }
        let result = try await request(endpoint: "search", items: items, diagnosticContext: diagnosticContext)
        if result.status == 404 { return [] }
        guard result.status == 200 else { throw PublicSourceError.http("LRCLib", result.status) }
        let records: [LrcLibResponse]
        if let timings { records = try timings.measure("decoding", { try decoder.decode([LrcLibResponse].self, from: result.data) }) }
        else { records = try decoder.decode([LrcLibResponse].self, from: result.data) }
        if records.isEmpty, let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib,
                phase: .providerEmpty, reason: .providerEmpty, endpoint: "search", httpStatus: 200, count: 0))
        }
        return records
    }

    private func request(endpoint: String, items: [URLQueryItem], diagnosticContext: LyricsLookupContext? = nil) async throws -> (data: Data, status: Int) {
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
        if let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .query,
                endpoint: endpoint, title: items.first { $0.name == "track_name" }?.value,
                artist: items.first { $0.name == "artist_name" }?.value,
                duration: items.first { $0.name == "duration" }.flatMap { Double($0.value ?? "") }))
        }
        let observer: ((PublicSourceRequest.TransportEvidence) -> Void)? = diagnosticContext.map { context in
            { evidence in
                LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .transportAttempt,
                    endpoint: endpoint, httpStatus: evidence.httpStatus, cacheSource: evidence.fetchSource,
                    attempt: evidence.attempt, transportErrorCode: evidence.transportErrorCode,
                    latencyMilliseconds: evidence.latencyMilliseconds))
            }
        }
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib", diagnostics: observer)
        try Task.checkCancellation()
        if let context = diagnosticContext {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrclib, phase: .response,
                reason: response.statusCode == 200 ? nil : .http, endpoint: endpoint, httpStatus: response.statusCode))
        }
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
    let instrumental: Bool?
    let syncedLyrics: String?
    let plainLyrics: String?
}
