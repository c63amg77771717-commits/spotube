import Foundation

/// Bounded, in-memory lookup evidence. Export only through the existing user action.
/// Never record lyrics text, headers, response bodies, cookies, credentials or URLs.
final class LyricsLookupDiagnostics: @unchecked Sendable {
    enum Phase: String, Codable, Sendable {
        case lookup, hypothesis, query, transportAttempt, response, providerEmpty, candidateDropped, candidateAccepted, selection, failure, result
    }
    enum Reason: String, Codable, Sendable {
        case missingMetadata, emptyContent, titleMismatch, versionMismatch, primaryPerformerMismatch, guestMismatch
        case identityMismatch, scoreBelowManual, autoSelected, rememberedSelected, manualRequired
        case providerEmpty, noUsableCandidate, allCandidatesRejected, plainOnly, timingUnknown, durationMismatch, instrumental
        case originalMetadata, derivedMetadata, reverseCredit, quotedTitleRetained, explicitBilingualCredit, identityConfirmationRequired
        case metadataRejected, cancelled, network, schema, http, rateLimited, providerUnavailable, secondaryDisabled
    }
    struct Event: Codable, Sendable {
        let timestamp: Date
        let lookupID: String
        let songID: String?
        let provider: LyricsProviderID?
        let album: String?
        let artistID: String?
        let albumID: String?
        let hasYouTubeOrigin: Bool
        let musicVideoType: String?
        let videoDuration: Int?
        let phase: Phase
        let reason: Reason?
        let endpoint: String?
        let title: String?
        let artist: String?
        let duration: Double?
        let recordID: String?
        let httpStatus: Int?
        let count: Int?
        let score: Int?
        let cacheSource: String
        let repositoryCacheSource: String
        let upstreamCacheSource: String
        let attempt: Int?
        let transportErrorCode: Int?
        let latencyMilliseconds: Int?
        init(context: LyricsLookupContext, provider: LyricsProviderID? = nil, phase: Phase,
             reason: Reason? = nil, endpoint: String? = nil, title: String? = nil, artist: String? = nil,
             duration: Double? = nil, recordID: String? = nil, httpStatus: Int? = nil, count: Int? = nil, score: Int? = nil,
             cacheSource: String = "not-observed", attempt: Int? = nil, transportErrorCode: Int? = nil,
             latencyMilliseconds: Int? = nil) {
            timestamp = Date(); lookupID = context.diagnosticLookupID; songID = Self.bounded(context.songID)
            self.provider = provider; self.phase = phase; self.reason = reason
            album = Self.bounded(context.album); artistID = Self.bounded(context.artistID); albumID = Self.bounded(context.albumID)
            hasYouTubeOrigin = context.hasYouTubeOrigin; musicVideoType = Self.bounded(context.musicVideoType); videoDuration = context.duration
            self.endpoint = Self.bounded(endpoint); self.title = Self.bounded(title); self.artist = Self.bounded(artist)
            self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.recordID = Self.bounded(recordID); self.httpStatus = httpStatus; self.count = count.map { max(0, min(10000, $0)) }
            self.score = score
            self.cacheSource = ["network", "local-cache", "server-push", "mixed", "not-observed"].contains(cacheSource) ? cacheSource : "not-observed"
            repositoryCacheSource = "uncached-provider-repository; selection-memory-separate"
            upstreamCacheSource = "not-observed"
            self.attempt = attempt.flatMap { (1...2).contains($0) ? $0 : nil }
            self.transportErrorCode = transportErrorCode
            self.latencyMilliseconds = latencyMilliseconds.map { max(0, min(60000, $0)) }
        }
        private static func bounded(_ value: String?) -> String? {
            guard let value, !value.contains("://") else { return nil }
            return String(String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(256))
        }
    }
    static let shared = LyricsLookupDiagnostics()
    private let lock = NSLock()
    private var entries: [Event] = []
    private let capacity: Int
    init(capacity: Int = 512) { self.capacity = max(8, min(2048, capacity)) }
    var events: [Event] { lock.withLock { entries } }
    func record(_ event: Event) {
        lock.withLock {
            entries.append(event)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }
    func clear() { lock.withLock { entries.removeAll() } }
    func recordHypotheses(_ metadata: LyricsCanonicalMetadata, provider: LyricsProviderID) {
        let context = metadata.context
        record(.init(context: context, provider: provider, phase: .hypothesis, reason: .derivedMetadata,
            title: metadata.pair.title, artist: metadata.pair.artist))
        if let reverse = metadata.alternateVideoPair {
            record(.init(context: context, provider: provider, phase: .hypothesis, reason: .reverseCredit,
                title: reverse.title, artist: reverse.artist))
        }
        if let quoted = metadata.quotedVideoPair {
            record(.init(context: context, provider: provider, phase: .hypothesis, reason: .quotedTitleRetained,
                title: quoted.title, artist: quoted.artist))
        }
        for artist in metadata.explicitArtistVariants {
            record(.init(context: context, provider: provider, phase: .hypothesis, reason: .explicitBilingualCredit,
                title: metadata.pair.title, artist: artist))
        }
        if metadata.requiresManualIdentityConfirmation {
            record(.init(context: context, provider: provider, phase: .hypothesis, reason: .identityConfirmationRequired))
        }
    }
    func recordFailure(context: LyricsLookupContext, provider: LyricsProviderID, error: Error) {
        let reason: Reason
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { reason = .cancelled }
        else if error is DecodingError { reason = .schema }
        else if error is URLError { reason = .network }
        else if let source = error as? PublicSourceError {
            switch source {
            case .http(_, let status): reason = status == 429 ? .rateLimited : .http
            case .invalidResponse: reason = .schema
            }
        } else { reason = .providerUnavailable }
        record(.init(context: context, provider: provider, phase: .failure, reason: reason))
    }
}
