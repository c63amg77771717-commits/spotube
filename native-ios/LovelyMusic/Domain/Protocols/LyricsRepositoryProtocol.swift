import Foundation

protocol LyricsRepositoryProtocol {
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport
    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics?
}

extension LyricsRepositoryProtocol {
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        try Task.checkCancellation()
        let lyrics = try await getLyrics(context: context)
        try Task.checkCancellation()
        return .legacy(lyrics)
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try await getLyrics(title: context.title, artist: context.artist, duration: context.duration,
                            allowVideoCredits: context.hasYouTubeOrigin)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration)
    }
}

enum LyricsProviderID: String, Codable, Hashable, Sendable {
    case lrclib, lrcapi
    var displayName: String { self == .lrclib ? "LRCLib" : "LrcApi" }
}

/// The provider namespace is part of equality: two providers may return the same ID.
struct LyricsRecordID: Codable, Hashable, Sendable {
    let providerID: LyricsProviderID
    let recordID: String
}

struct LyricsSourceFailure: Sendable {
    let providerID: LyricsProviderID
    let message: String
    let httpStatus: Int?
    let reason: LyricsLookupDiagnostics.Reason
    var displayLabel: String {
        if let httpStatus { return providerID.displayName + " (HTTP " + String(httpStatus) + ")" }
        return providerID.displayName
    }

    init(providerID: LyricsProviderID, message: String, httpStatus: Int? = nil, reason: LyricsLookupDiagnostics.Reason? = nil) {
        self.providerID = providerID; self.message = message; self.httpStatus = httpStatus
        self.reason = reason ?? (httpStatus == nil ? .providerUnavailable : httpStatus == 429 ? .rateLimited : .http)
    }

    /// Adapters may already report multiple typed failures. Keep their provenance
    /// instead of relabeling the entire rendered error as a new provider failure.
    static func from(_ error: Error, providerID: LyricsProviderID) -> [LyricsSourceFailure] {
        if let lookupError = error as? LyricsLookupError {
            switch lookupError {
            case .unavailable(let failures): return failures
            }
        }
        let status: Int?
        if let source = error as? PublicSourceError, case .http(_, let code) = source { status = code }
        else { status = nil }
        let reason: LyricsLookupDiagnostics.Reason
        if let status { reason = status == 429 ? .rateLimited : .http }
        else if error is URLError { reason = .network }
        else if error is DecodingError || error is PublicSourceError { reason = .schema }
        else { reason = .providerUnavailable }
        return [.init(providerID: providerID, message: error.localizedDescription, httpStatus: status, reason: reason)]
    }
}

enum LyricsLookupError: Error, LocalizedError {
    case unavailable([LyricsSourceFailure])
    var errorDescription: String? {
        switch self {
        case .unavailable(let failures):
            return failures.map { failure in
                let source = failure.providerID.displayName
                // PublicSourceError already includes its source name.
                if failure.message.hasPrefix(source + " ") || failure.message.hasPrefix(source + ":") {
                    return failure.message
                }
                return "\(source): \(failure.message)"
            }.joined(separator: "; ")
        }
    }
}

enum LyricsTimingState: String, Equatable {
    case structurallyCompatible, plainOnly, timingUnknown, durationMismatch, invalidTimestamp, unsupportedTiming
}

struct SyncedLyrics {
    let lines: [LyricLine]
    let source: String
    let providerID: LyricsProviderID?
    let isTimeSynced: Bool
    let candidates: [LyricsCandidate]
    let selectionKey: String?
    let sourceFailures: [LyricsSourceFailure]
    let timingState: LyricsTimingState

    init(lines: [LyricLine], source: String, isTimeSynced: Bool = true,
         candidates: [LyricsCandidate] = [], selectionKey: String? = nil,
         providerID: LyricsProviderID? = nil, sourceFailures: [LyricsSourceFailure] = [],
         timingState: LyricsTimingState? = nil) {
        self.lines = lines
        self.source = source
        self.providerID = providerID
        let resolvedTiming = timingState ?? (isTimeSynced ? LyricsTimingState.structurallyCompatible : .plainOnly)
        self.timingState = resolvedTiming
        self.isTimeSynced = isTimeSynced && resolvedTiming == .structurallyCompatible
        self.candidates = candidates
        self.selectionKey = selectionKey
        self.sourceFailures = sourceFailures
    }
}

struct LyricsCandidate: Identifiable {
    let id: LyricsRecordID
    let title: String
    let artist: String
    let duration: Double?
    let lyrics: SyncedLyrics
    let album: String?
    let identityDecision: LyricsIdentityDecision?

    init(id: LyricsRecordID, title: String, artist: String, duration: Double?, lyrics: SyncedLyrics, album: String? = nil,
         identityDecision: LyricsIdentityDecision? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration
        self.lyrics = lyrics; self.album = album; self.identityDecision = identityDecision
    }

    func withIdentityDecision(_ decision: LyricsIdentityDecision) -> LyricsCandidate {
        .init(id: id, title: title, artist: artist, duration: duration, lyrics: lyrics, album: album, identityDecision: decision)
    }

    var timingLabel: String {
        LocalizationManager.text(lyrics.isTimeSynced ? "Synced lyrics" : "Lyrics timing unavailable")
    }
    var versionLabel: String {
        let tags = LyricsCanonicalMetadata.versions(title).union(album.map(LyricsCanonicalMetadata.versions) ?? [])
        return tags.isEmpty ? LocalizationManager.text("Version unspecified") : tags.sorted().joined(separator: ", ")
    }

    var providerID: LyricsProviderID { id.providerID }
    var recordID: String { id.recordID }
    var accessibilityID: String {
        // Preserve the existing LRCLib UI test identifiers; namespace the new provider.
        providerID == .lrclib ? "lyrics_candidate_\(recordID)" : "lyrics_candidate_lrcapi_\(recordID)"
    }
    var durationLabel: String {
        guard let duration, duration.isFinite, (0...86400).contains(duration) else { return "?" }
        let seconds = Int(duration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum LyricsSelectionStore {
    static func selectedRecord(for key: String, defaults: UserDefaults = .standard) -> LyricsRecordID? {
        let name = "lyrics.selection." + key
        if let value = defaults.dictionary(forKey: name),
           let provider = value["providerID"] as? String, let id = value["recordID"] as? String,
           let providerID = LyricsProviderID(rawValue: provider), !id.isEmpty {
            return LyricsRecordID(providerID: providerID, recordID: id)
        }
        if let legacy = defaults.object(forKey: name) as? Int {
            let migrated = LyricsRecordID(providerID: .lrclib, recordID: String(legacy))
            select(migrated, for: key, defaults: defaults)
            return migrated
        }
        return nil
    }

    static func select(_ id: LyricsRecordID, for key: String, defaults: UserDefaults = .standard) {
        defaults.set(["providerID": id.providerID.rawValue, "recordID": id.recordID],
                     forKey: "lyrics.selection." + key)
    }

    /// Source compatibility for the existing LRCLib-only selection callers.
    static func select(_ id: Int, for key: String, defaults: UserDefaults = .standard) {
        select(LyricsRecordID(providerID: .lrclib, recordID: String(id)), for: key, defaults: defaults)
    }
}

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}
