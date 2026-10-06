import Foundation

/// Primary-first lookup; independent candidate recordings never share a timeline.
final class CompositeLyricsRepository: LyricsRepositoryProtocol {
    private let primary: LyricsRepositoryProtocol
    private let secondary: LyricsRepositoryProtocol
    private let defaults: UserDefaults
    private let secondaryEnabled: () -> Bool

    init(primary: LyricsRepositoryProtocol, secondary: LyricsRepositoryProtocol,
         defaults: UserDefaults = .standard, secondaryEnabled: (() -> Bool)? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.defaults = defaults
        self.secondaryEnabled = secondaryEnabled ?? { LyricsSecondarySettings.isEnabled(defaults: defaults) }
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .lookup, reason: .originalMetadata,
            title: context.title, artist: context.artist, duration: context.duration.map { Double($0) }))
        guard let metadata = LyricsCanonicalMetadata(context) else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .result, reason: .metadataRejected))
            return nil
        }
        let saved = LyricsCandidateScorer.remembered(context, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var first: SyncedLyrics?
        do {
            first = try await primary.getLyrics(context: context)
            try Task.checkCancellation()
            failures += first?.sourceFailures ?? []
        } catch {
            try LyricsMatchingPolicy.checkCancellation(error)
            failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
        }
        let enabled = secondaryEnabled()
        if let first, !first.lines.isEmpty, first.isTimeSynced,
           !enabled || saved?.providerID != .lrcapi { return first }
        guard enabled else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .result, reason: .secondaryDisabled))
            if let first { return first }
            if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
            return nil
        }
        var second: SyncedLyrics?
        do {
            second = try await secondary.getLyrics(context: context)
            try Task.checkCancellation()
            failures += second?.sourceFailures ?? []
        } catch {
            try LyricsMatchingPolicy.checkCancellation(error)
            failures.append(.init(providerID: .lrcapi, message: error.localizedDescription))
        }
        try Task.checkCancellation()
        if !secondaryEnabled() {
            if let first { return first }
            let primaryFailures = failures.filter { $0.providerID == .lrclib }
            if !primaryFailures.isEmpty { throw LyricsLookupError.unavailable(primaryFailures) }
            return nil
        }
        let candidates = (first?.candidates ?? []) + (second?.candidates ?? [])
        if !candidates.isEmpty {
            return LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures)
        }
        if let content = second ?? first, !content.lines.isEmpty {
            return SyncedLyrics(lines: content.lines, source: content.source, isTimeSynced: content.isTimeSynced,
                                selectionKey: context.selectionKey, providerID: content.providerID, sourceFailures: failures)
        }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        let key = LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        let remembered = LyricsSelectionStore.selectedRecord(for: key, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var first: SyncedLyrics?
        do {
            first = try await primary.getLyrics(title: title, artist: artist, duration: duration,
                                                allowVideoCredits: allowVideoCredits)
            try Task.checkCancellation()
            failures += first?.sourceFailures ?? []
        } catch {
            try LyricsMatchingPolicy.checkCancellation(error)
            failures.append(LyricsSourceFailure(providerID: .lrclib, message: error.localizedDescription))
        }
        let enabled = secondaryEnabled()
        if let first, !first.lines.isEmpty, first.isTimeSynced,
           !enabled || remembered?.providerID != .lrcapi { return first }
        guard enabled else {
            if let first { return first }
            if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
            return nil
        }
        try Task.checkCancellation()
        var second: SyncedLyrics?
        do {
            second = try await secondary.getLyrics(title: title, artist: artist, duration: duration,
                                                   allowVideoCredits: allowVideoCredits)
            try Task.checkCancellation()
            failures += second?.sourceFailures ?? []
        } catch {
            try LyricsMatchingPolicy.checkCancellation(error)
            failures.append(LyricsSourceFailure(providerID: .lrcapi, message: error.localizedDescription))
        }
        try Task.checkCancellation()
        // A switch turned off during a request must not surface secondary content.
        if !secondaryEnabled() {
            if let first { return first }
            let primaryFailures = failures.filter { $0.providerID == .lrclib }
            if !primaryFailures.isEmpty { throw LyricsLookupError.unavailable(primaryFailures) }
            return nil
        }
        let candidates = (first?.candidates ?? []) + (second?.candidates ?? [])
        if !candidates.isEmpty {
            let pair = LyricsLookupMetadata.secondaryPair(title: title, artist: artist,
                                                         allowVideoCredits: allowVideoCredits)
            return LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: pair?.artist.isEmpty ?? true,
                                               defaults: defaults, failures: failures)
        }
        if let content = second ?? first, !content.lines.isEmpty {
            return SyncedLyrics(lines: content.lines, source: content.source, isTimeSynced: content.isTimeSynced,
                                selectionKey: key, providerID: content.providerID, sourceFailures: failures)
        }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }
}
