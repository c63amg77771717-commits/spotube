import Foundation

/// Primary-first lookup; independent candidate recordings never share a timeline.
final class CompositeLyricsRepository: LyricsRepositoryProtocol {
    private let primary: LyricsRepositoryProtocol
    private let secondary: LyricsRepositoryProtocol
    private let defaults: UserDefaults
    private let secondaryEnabled: () -> Bool
    private let probeBothSources: Bool

    init(primary: LyricsRepositoryProtocol, secondary: LyricsRepositoryProtocol,
         defaults: UserDefaults = .standard, secondaryEnabled: (() -> Bool)? = nil, probeBothSources: Bool = false) {
        self.probeBothSources = probeBothSources
        self.primary = primary
        self.secondary = secondary
        self.defaults = defaults
        self.secondaryEnabled = secondaryEnabled ?? { LyricsSecondarySettings.isEnabled(defaults: defaults) }
    }

    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try await lookup(context: context).legacyValue()
    }

    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        let timings = LyricsLookupStageTimings()
        defer { timings.record(context: context, provider: nil, wallStage: "compositeWall") }
        try Task.checkCancellation()
        LyricsLookupDiagnostics.shared.record(.init(context: context, phase: .lookup, reason: .originalMetadata,
            title: context.title, artist: context.artist, duration: context.duration.map { Double($0) }))
        guard let metadata = timings.measure("compositeMetadataAndHypotheses", { LyricsCanonicalMetadata(context) }) else { return .metadataRejected() }
        let saved = LyricsCandidateScorer.remembered(context, defaults: defaults)
        func source(_ repository: LyricsRepositoryProtocol, provider: LyricsProviderID) async throws -> LyricsLookupReport {
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                LyricsLookupDiagnostics.shared.record(.init(context: context, provider: provider, phase: .stageTiming,
                    stage: provider == .lrclib ? "primarySourceAwait" : "secondarySourceAwait",
                    stageElapsedMilliseconds: max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
            }
            do {
                let report = try await repository.lookup(context: context)
                try Task.checkCancellation()
                return report
            } catch {
                try LyricsMatchingPolicy.checkCancellation(error)
                return .provider(provider, lyrics: nil, received: 0, successfulResponses: 0,
                                 failures: LyricsSourceFailure.from(error, providerID: provider))
            }
        }
        let first = try await source(primary, provider: .lrclib)
        try Task.checkCancellation()
        let enabled = secondaryEnabled()
        let needsDirectionEvidence = LyricsDirectionPolicy.requiresEvidence(metadata)
        if !probeBothSources, !needsDirectionEvidence, let content = first.lyrics, !content.lines.isEmpty, content.isTimeSynced,
           !enabled || saved?.providerID != .lrcapi { return first }
        guard enabled else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .result, reason: .secondaryDisabled))
            return first
        }
        let second = try await source(secondary, provider: .lrcapi)
        try Task.checkCancellation()
        // A setting disabled in flight excludes both secondary content and evidence.
        guard secondaryEnabled() else {
            LyricsLookupDiagnostics.shared.record(.init(context: context, provider: .lrcapi, phase: .result, reason: .secondaryDisabled))
            return first
        }
        let providers = first.providers + second.providers
        let failures = first.failures + second.failures
        let directionEvidence = needsDirectionEvidence ? LyricsDirectionEvidence(
            candidates: (first.directionEvidence?.candidates ?? first.lyrics?.candidates ?? [])
                + (second.directionEvidence?.candidates ?? second.lyrics?.candidates ?? []),
            coverage: (first.directionEvidence?.coverage ?? [.unavailable])
                + (second.directionEvidence?.coverage ?? [.unavailable])) : nil
        let candidates = directionEvidence?.candidates
            ?? ((first.lyrics?.candidates ?? []) + (second.lyrics?.candidates ?? []))
        if !candidates.isEmpty {
            let lyrics = timings.measure("compositeSelectionAndScoring", { LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures,
                    directionCoverage: directionEvidence?.coverage ?? []) })
            let evaluatedProviders = lyrics == nil ? providers.map { outcome in
                LyricsProviderOutcome(providerID: outcome.providerID, kind: outcome.kind == .usable ? .rejected : outcome.kind,
                    receivedCount: outcome.receivedCount, acceptedCount: 0, successfulResponses: outcome.successfulResponses,
                    failures: outcome.failures, contentCandidateCount: outcome.contentCandidateCount,
                    rejectionReasons: outcome.rejectionReasons, evaluatedCandidates: outcome.evaluatedCandidates, stageTimings: outcome.stageTimings)
            } : providers
            return .init(lyrics: lyrics, providers: evaluatedProviders, directionEvidence: directionEvidence, queryReceipts: first.queryReceipts + second.queryReceipts)
        }
        if !needsDirectionEvidence, let content = second.lyrics ?? first.lyrics, !content.lines.isEmpty {
            let lyrics = SyncedLyrics(lines: content.lines, source: content.source, isTimeSynced: content.isTimeSynced,
                selectionKey: context.selectionKey, providerID: content.providerID, sourceFailures: failures, timingState: content.timingState)
            return .init(lyrics: lyrics, providers: providers, queryReceipts: first.queryReceipts + second.queryReceipts)
        }
        return .init(lyrics: nil, providers: providers, directionEvidence: directionEvidence, queryReceipts: first.queryReceipts + second.queryReceipts)
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
            failures += LyricsSourceFailure.from(error, providerID: .lrclib)
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
            failures += LyricsSourceFailure.from(error, providerID: .lrcapi)
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
            guard let metadata = LyricsCanonicalMetadata(.init(title: title, artist: artist, duration: duration,
                                                                hasYouTubeOrigin: allowVideoCredits)) else { return nil }
            return LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures)
        }
        if let content = second ?? first, !content.lines.isEmpty {
            return SyncedLyrics(lines: content.lines, source: content.source, isTimeSynced: content.isTimeSynced,
                                selectionKey: key, providerID: content.providerID, sourceFailures: failures, timingState: content.timingState)
        }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }
}
