import Foundation

protocol LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics?
}

extension LyricsRepositoryProtocol {
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
}

enum LyricsLookupError: Error, LocalizedError {
    case unavailable([LyricsSourceFailure])
    var errorDescription: String? {
        switch self {
        case .unavailable(let failures):
            return failures.map { "\($0.providerID.displayName): \($0.message)" }.joined(separator: "; ")
        }
    }
}

struct SyncedLyrics {
    let lines: [LyricLine]
    let source: String
    let providerID: LyricsProviderID?
    let isTimeSynced: Bool
    let candidates: [LyricsCandidate]
    let selectionKey: String?
    let sourceFailures: [LyricsSourceFailure]

    init(lines: [LyricLine], source: String, isTimeSynced: Bool = true,
         candidates: [LyricsCandidate] = [], selectionKey: String? = nil,
         providerID: LyricsProviderID? = nil, sourceFailures: [LyricsSourceFailure] = []) {
        self.lines = lines
        self.source = source
        self.providerID = providerID
        self.isTimeSynced = isTimeSynced
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
