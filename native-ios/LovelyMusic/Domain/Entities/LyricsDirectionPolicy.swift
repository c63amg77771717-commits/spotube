import Foundation

/// Evidence is scoped to a single provider lookup. A failed, truncated or malformed
/// response cannot establish absence of a conflicting title/artist direction.
struct LyricsDirectionCoverage: Hashable {
    private(set) var completedPairs: Set<String> = []
    private(set) var incomplete = false

    static func key(_ pair: LyricsLookupMetadata.Pair) -> String {
        LyricsLookupMetadata.identityKey(pair.title) + "|" + LyricsLookupMetadata.performerKey(pair.artist)
    }
    mutating func recordSuccess(_ pair: LyricsLookupMetadata.Pair, recordCount: Int, metadataComplete: Bool = true) {
        guard recordCount >= 0, recordCount <= 30, metadataComplete else { incomplete = true; return }
        completedPairs.insert(Self.key(pair))
    }
    mutating func recordFailure() { incomplete = true }
    func covers(_ pairs: [LyricsLookupMetadata.Pair]) -> Bool {
        !incomplete && pairs.allSatisfy { completedPairs.contains(Self.key($0)) }
    }
    static var unavailable: Self { var value = Self(); value.recordFailure(); return value }
}

/// Retains raw valid candidates before identity filtering so a provider cannot hide
/// a conflicting direction from composite selection. Never persisted or cached.
struct LyricsDirectionEvidence {
    let candidates: [LyricsCandidate]
    let coverage: [LyricsDirectionCoverage]
}

enum LyricsDirectionPolicy {
    /// Only the existing bounded dash/quote hypotheses qualify. Unbounded whitespace,
    /// a bare track plus uploader, duet-name splitting and supplied contradictions do not.
    static func hypotheses(_ metadata: LyricsCanonicalMetadata) -> [LyricsIdentityHypothesis] {
        guard metadata.context.hasYouTubeOrigin, metadata.originalArtist.isEmpty,
              metadata.requiresManualIdentityConfirmation,
              !LyricsLookupMetadata.isWhitespaceVideoCredit(metadata.context.title),
              LyricsLookupMetadata.videoCreditPairs(metadata.context).count == 2 else { return [] }
        var seen = Set<String>()
        let values = metadata.hypotheses.filter {
            !$0.pair.title.isEmpty && !$0.pair.artist.isEmpty && $0.evidence != .literal
                && seen.insert(LyricsDirectionCoverage.key($0.pair)).inserted
        }
        return values.count >= 2 ? values : []
    }

    static func requiresEvidence(_ metadata: LyricsCanonicalMetadata) -> Bool { !hypotheses(metadata).isEmpty }

    /// Prioritize the same existing semantic probes within the unchanged six-query
    /// budget. If a required variant falls outside the budget it stays unconfirmed.
    static func requiredPairs(_ metadata: LyricsCanonicalMetadata) -> [LyricsLookupMetadata.Pair] {
        var seen = Set<String>()
        return hypotheses(metadata).flatMap { hypothesis in
            hypothesis.titleVariants.map { LyricsLookupMetadata.Pair(title: $0, artist: hypothesis.pair.artist) }
        }.filter { seen.insert(LyricsDirectionCoverage.key($0)).inserted }
    }

    /// This confirms a metadata interpretation, not an audio recording. Recording
    /// uniqueness and timing remain the responsibility of the existing selector.
    static func confirmedHypothesisIDs(_ candidates: [LyricsCandidate], metadata: LyricsCanonicalMetadata,
                                       coverage: [LyricsDirectionCoverage]) -> Set<String> {
        guard !Task.isCancelled else { return [] }
        let directions = hypotheses(metadata)
        let required = requiredPairs(metadata)
        guard !directions.isEmpty, !coverage.isEmpty,
              coverage.allSatisfy({ $0.covers(required) }) else { return [] }
        let supported = directions.filter { direction in
            candidates.contains { LyricsIdentityPolicy.hasCompleteDirectionIdentity($0, hypothesis: direction, metadata: metadata) }
        }
        guard supported.count == 1, let direction = supported.first else { return [] }
        let ids: Set<String> = [direction.id]
        // Existing score/version/guest gates still apply. Only the source direction cap
        // is removable; remembered selections cannot supply missing source evidence.
        guard candidates.contains(where: {
            LyricsIdentityPolicy.hasCompleteDirectionIdentity($0, hypothesis: direction, metadata: metadata)
                && LyricsIdentityPolicy.decision($0, metadata: metadata, confirmedDirectionIDs: ids).kind == .confirmed
        }) else { return [] }
        return ids
    }
}
