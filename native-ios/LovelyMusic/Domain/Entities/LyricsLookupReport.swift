import Foundation

/// A lookup result is independent of transport errors and the selected timeline.
enum LyricsLookupState: String, Equatable {
    case sourceUnavailable, providerEmpty, candidatesRejected, manualSelection, confirmedPlain, synchronized, metadataRejected

    var message: String {
        let key: String.LocalizationValue
        switch self {
        case .sourceUnavailable: key = "Lyrics source temporarily unavailable"
        case .providerEmpty: key = "Lyrics sources returned no results"
        case .candidatesRejected: key = "Returned lyrics did not match this song"
        case .manualSelection: key = "Choose a matching performer and version"
        case .confirmedPlain: key = "Lyrics timing unavailable"
        case .synchronized: key = "Synced lyrics"
        case .metadataRejected: key = "Song metadata is insufficient for lyrics lookup"
        }
        return LocalizationManager.text(key)
    }
}

/// Bounded response evidence, including rejected records. Never includes lyric text or user video IDs.
struct LyricsCandidateEvidence: Codable {
    let provider: String
    let recordID: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let queryEndpoint: String?
    let queryTitle: String?
    let queryArtist: String?
    let identity: String
    let reason: String?
    let score: Int
    let scoreBreakdown: [String: Int]
    let hypothesisID: String?
    let canonicalTitle: String
    let canonicalArtist: String
    let titleVariants: [String]
    let versionTags: [String]
    let contentLineCount: Int
    let timing: String
    let actualVocalAlignment: String

    init(provider: LyricsProviderID, recordID: String?, title: String?, artist: String?, album: String?,
         duration: Double?, metadata: LyricsCanonicalMetadata, candidate: LyricsCandidate? = nil,
         discardedReason: LyricsLookupDiagnostics.Reason? = nil, remembered: LyricsRecordID? = nil,
         queryEndpoint: String? = nil, queryTitle: String? = nil, queryArtist: String? = nil) {
        let decision = candidate.map { LyricsCandidateScorer.decision($0, metadata: metadata, remembered: remembered) }
        let hypothesis = metadata.hypotheses.first { $0.id == decision?.hypothesisID }
        self.provider = provider.rawValue; self.recordID = recordID
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        self.queryEndpoint = queryEndpoint; self.queryTitle = queryTitle; self.queryArtist = queryArtist
        identity = discardedReason != nil ? "rejected" : (decision?.kind.rawValue ?? "rejected")
        reason = (discardedReason ?? decision?.reason)?.rawValue
        score = discardedReason == nil ? (decision?.score ?? 0) : 0
        scoreBreakdown = discardedReason == nil ? (decision?.scoreBreakdown ?? [:]) : [:]
        hypothesisID = decision?.hypothesisID
        canonicalTitle = hypothesis?.pair.title ?? metadata.pair.title
        canonicalArtist = hypothesis?.pair.artist ?? metadata.pair.artist
        titleVariants = hypothesis?.titleVariants ?? metadata.explicitTitleVariants
        versionTags = LyricsCanonicalMetadata.versions(title ?? "").sorted()
        contentLineCount = candidate?.lyrics.lines.count ?? 0
        timing = candidate?.lyrics.timingState.rawValue ?? "noContent"
        actualVocalAlignment = "NOT_RUN"
    }
}

struct LyricsProviderOutcome {
    enum Kind: String, Equatable { case unavailable, empty, rejected, usable, metadataRejected }
    let providerID: LyricsProviderID?
    let kind: Kind
    /// Counts refer to bounded records inspected, not distinct songs or HTTP attempts.
    let receivedCount: Int
    let rejectionReasons: [String: Int]
    let evaluatedCandidates: [LyricsCandidateEvidence]
    let contentCandidateCount: Int
    let acceptedCount: Int
    let successfulResponses: Int
    let failures: [LyricsSourceFailure]
    /// Retained per-result timing evidence survives the bounded diagnostics ring.
    /// Intervals overlap; wall time is not a CPU sample or sum of these stages.
    let stageTimings: [String: Double]
    init(providerID: LyricsProviderID?, kind: Kind, receivedCount: Int, acceptedCount: Int,
         successfulResponses: Int, failures: [LyricsSourceFailure], contentCandidateCount: Int = 0, rejectionReasons: [String: Int] = [:], evaluatedCandidates: [LyricsCandidateEvidence] = [], stageTimings: [String: Double] = [:]) {
        self.providerID = providerID; self.kind = kind; self.receivedCount = receivedCount
        self.acceptedCount = acceptedCount; self.successfulResponses = successfulResponses
        self.failures = failures; self.contentCandidateCount = contentCandidateCount; self.rejectionReasons = rejectionReasons
        self.evaluatedCandidates = evaluatedCandidates
        self.stageTimings = stageTimings
    }
}

struct LyricsLookupReport {
    var diagnosticContext: LyricsLookupContext? = nil
    let lyrics: SyncedLyrics?
    let providers: [LyricsProviderOutcome]
    var failures: [LyricsSourceFailure] { providers.flatMap(\.failures) }
    var canRetryAvailability: Bool { !failures.isEmpty }
    var failureSummary: String { Array(Set(failures.map(\.displayLabel))).sorted().joined(separator: ", ") }
    var state: LyricsLookupState {
        if let lyrics {
            if !lyrics.lines.isEmpty { return lyrics.isTimeSynced ? .synchronized : .confirmedPlain }
            if !lyrics.candidates.isEmpty { return .manualSelection }
        }
        // An observed nonempty response outranks an unrelated source's failure.
        if providers.contains(where: { $0.kind == .rejected }) { return .candidatesRejected }
        if providers.contains(where: { $0.kind == .empty }) { return .providerEmpty }
        if providers.contains(where: { $0.kind == .metadataRejected }) { return .metadataRejected }
        return failures.isEmpty ? .providerEmpty : .sourceUnavailable
    }

    /// Preserve optional/error behavior for older callers; the player uses the report.
    func legacyValue() throws -> SyncedLyrics? {
        if let lyrics { return lyrics }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }

    static func provider(_ id: LyricsProviderID, lyrics: SyncedLyrics?, received: Int,
                         successfulResponses: Int, failures: [LyricsSourceFailure], contentCandidates: Int = 0, rejectionReasons: [String: Int] = [:], evaluatedCandidates: [LyricsCandidateEvidence] = [], stageTimings: [String: Double] = [:]) -> LyricsLookupReport {
        let accepted = lyrics?.candidates.count ?? 0
        let usable = lyrics.map { !$0.lines.isEmpty || !$0.candidates.isEmpty } ?? false
        let kind: LyricsProviderOutcome.Kind = usable ? .usable : received > 0 ? .rejected
            : successfulResponses > 0 ? .empty : !failures.isEmpty ? .unavailable : .empty
        return .init(lyrics: lyrics, providers: [.init(providerID: id, kind: kind,
            receivedCount: received, acceptedCount: accepted, successfulResponses: successfulResponses, failures: failures,
            contentCandidateCount: max(contentCandidates, accepted), rejectionReasons: rejectionReasons, evaluatedCandidates: evaluatedCandidates, stageTimings: stageTimings)])
    }

    static func metadataRejected(provider: LyricsProviderID? = nil) -> LyricsLookupReport {
        .init(lyrics: nil, providers: [.init(providerID: provider, kind: .metadataRejected,
            receivedCount: 0, acceptedCount: 0, successfulResponses: 0, failures: [])])
    }

    /// Compatibility for injected/older repositories. No fictitious HTTP status.
    static func legacy(_ lyrics: SyncedLyrics?, failures: [LyricsSourceFailure] = []) -> LyricsLookupReport {
        let combined = failures + (lyrics?.sourceFailures ?? [])
        let usable = lyrics.map { !$0.lines.isEmpty || !$0.candidates.isEmpty } ?? false
        return .init(lyrics: lyrics, providers: [.init(providerID: lyrics?.providerID,
            kind: usable ? .usable : combined.isEmpty ? .empty : .unavailable,
            receivedCount: lyrics?.candidates.count ?? 0, acceptedCount: lyrics?.candidates.count ?? 0,
            successfulResponses: 0, failures: combined)])
    }

    func recordFinal(context: LyricsLookupContext, lookupLatencyMilliseconds: Int? = nil) {
        let reason: LyricsLookupDiagnostics.Reason
        switch state {
        case .sourceUnavailable: reason = .providerUnavailable
        case .providerEmpty: reason = .providerEmpty
        case .candidatesRejected: reason = .allCandidatesRejected
        case .manualSelection: reason = .manualRequired
        case .confirmedPlain: reason = .plainOnly
        case .synchronized: reason = .timingCompatible
        case .metadataRejected: reason = .metadataRejected
        }
        LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .result, reason: reason,
            count: lyrics?.candidates.count ?? 0, outcome: state.rawValue, lookupLatencyMilliseconds: lookupLatencyMilliseconds))
    }
}
