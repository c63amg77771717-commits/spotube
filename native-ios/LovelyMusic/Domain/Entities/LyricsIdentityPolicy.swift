import Foundation

/// These are lookup-only views of immutable Song metadata, never new source facts.
struct LyricsIdentityHypothesis {
    enum Evidence: String, Equatable { case literal, trustedPerformer, boundedVideoCredit, uncertainCredit, reverseCredit, retainedQuote }
    let id: String
    let pair: LyricsLookupMetadata.Pair
    let titleVariants: [String]
    let evidence: Evidence
    let allowsAutomaticSelection: Bool
    let normalization: [LyricsLookupMetadata.NormalizationStep]
}

struct LyricsIdentityDecision {
    enum Kind: String, Equatable { case confirmed, relatedManual, rejected }
    let kind: Kind
    let score: Int
    let reason: LyricsLookupDiagnostics.Reason?
    let hypothesisID: String?
    var allowsAutomaticSelection: Bool { kind == .confirmed }
}

enum LyricsIdentityPolicy {
    private static func equivalentCredits(_ left: String, _ right: String, video: Bool) -> Bool {
        func aliases(_ credit: String) -> Set<String> {
            var values = [credit]
            if video, let regex = try? NSRegularExpression(pattern: "^([\\p{Han}]{2,})\\s+([A-Za-z][A-Za-z .'-]*)$"),
               let match = regex.firstMatch(in: credit, range: NSRange(credit.startIndex..., in: credit)),
               let han = Range(match.range(at: 1), in: credit), let latin = Range(match.range(at: 2), in: credit) {
                values += [String(credit[han]), String(credit[latin])]
            }
            return Set(values.map { LyricsCanonicalMetadata.artistIdentity(LyricsLookupMetadata.identityKey($0)) })
        }
        let lhs = LyricsCanonicalMetadata.creditComponents(left).map(aliases)
        var rhs = LyricsCanonicalMetadata.creditComponents(right).map(aliases)
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        for group in lhs {
            guard let index = rhs.firstIndex(where: { !group.isDisjoint(with: $0) }) else { return false }
            rhs.remove(at: index)
        }
        return true
    }
    /// Literal + derived + at most two existing role alternatives; no recursive re-normalization.
    static func hypotheses(_ metadata: LyricsCanonicalMetadata) -> [LyricsIdentityHypothesis] {
        let context = metadata.context
        let trusted = metadata.originalArtist
        let explicit = context.hasYouTubeOrigin
            ? LyricsLookupMetadata.bracketedVideoCredit(LyricsLookupMetadata.strippingVideoPresentation(context.title)) : nil
        let supplied = !trusted.isEmpty
        let rolePairs = LyricsLookupMetadata.videoCreditPairs(context)
        let conflict = supplied && explicit.map { !equivalentCredits($0.artist, trusted, video: context.hasYouTubeOrigin) } == true
            || supplied && !rolePairs.isEmpty && !rolePairs.contains {
                equivalentCredits($0.artist, trusted, video: context.hasYouTubeOrigin)
            }
        let hasPresentation = LyricsLookupMetadata.strippingVideoPresentation(context.title) != context.title
        let ambiguousOrder = !supplied && (LyricsLookupMetadata.videoCreditPairs(context).count == 2
            || LyricsLookupMetadata.isWhitespaceVideoCredit(context.title))
        let quoteRemoved = metadata.quotedVideoPair != nil
        // A song span plus an observed presentation label establishes roles more
        // strongly than bare brackets, a dash or uploader text on their own.
        let bounded = explicit != nil && (hasPresentation || supplied) && !conflict
        let primaryAutomatic = !metadata.pair.artist.isEmpty && !ambiguousOrder && !quoteRemoved
            && !conflict && (supplied || bounded)
        let primaryEvidence: LyricsIdentityHypothesis.Evidence = metadata.pair.title == metadata.originalTitle
            && metadata.pair.artist == trusted ? .literal
            : bounded ? .boundedVideoCredit : supplied ? .trustedPerformer : .uncertainCredit
        var values = [LyricsIdentityHypothesis(id: "derived", pair: metadata.pair,
            titleVariants: metadata.explicitTitleVariants,
            evidence: primaryEvidence,
            allowsAutomaticSelection: primaryAutomatic,
            normalization: LyricsLookupMetadata.normalizationSteps(context: context, pair: metadata.pair))]
        values.append(.init(id: "literal", pair: .init(title: metadata.originalTitle, artist: trusted),
            titleVariants: [metadata.originalTitle], evidence: .literal,
            allowsAutomaticSelection: supplied, normalization: []))
        for (index, pair) in metadata.alternativePairs.prefix(2).enumerated() {
            // A weak title parse must never contradict a supplied performer.
            if supplied && !equivalentCredits(pair.artist, trusted, video: context.hasYouTubeOrigin) { continue }
            values.append(.init(id: "alternative-" + String(index), pair: pair, titleVariants: [pair.title],
                evidence: metadata.quotedVideoPair?.title == pair.title ? .retainedQuote : .reverseCredit,
                allowsAutomaticSelection: false,
                normalization: [.init(before: context.title, after: pair.title, reason: .uncertainRoleAlternative)]))
        }
        var seen = Set<String>()
        return Array(values.filter {
            seen.insert($0.pair.title + "|" + $0.pair.artist + "|" + String($0.allowsAutomaticSelection)).inserted
        }.prefix(4))
    }

    private static func performerIdentity(_ token: String, hypothesis: LyricsIdentityHypothesis,
                                          video: Bool) -> String {
        if video, let regex = try? NSRegularExpression(pattern: "^([\\p{Han}]{2,})\\s+([A-Za-z][A-Za-z .'-]*)$") {
            for credit in LyricsCanonicalMetadata.creditComponents(hypothesis.pair.artist) {
                guard let match = regex.firstMatch(in: credit, range: NSRange(credit.startIndex..., in: credit)),
                      let han = Range(match.range(at: 1), in: credit),
                      let latin = Range(match.range(at: 2), in: credit) else { continue }
                let keys = [credit, String(credit[han]), String(credit[latin])].map(LyricsLookupMetadata.identityKey)
                if keys.contains(token) { return LyricsCanonicalMetadata.artistIdentity(keys[0]) }
            }
        }
        return LyricsCanonicalMetadata.artistIdentity(token)
    }

    private static func hasOrderedCredit(_ artist: String) -> Bool {
        artist.range(of: "(?i)\\b(?:feat(?:uring)?|ft|with)\\.?\\s+", options: .regularExpression) != nil
    }

    private struct CandidateView { let title: String; let artist: String }
    private static func candidateViews(_ candidate: LyricsCandidate) -> [CandidateView] {
        var values = [CandidateView(title: candidate.title, artist: candidate.artist)]
        // A complete trailing feat credit can supplement performer metadata.
        // The literal title remains available; arbitrary bracket subtitles survive.
        let pattern = "(?i)^(.+?)\\s*[\\[(]\\s*(?:feat(?:uring)?|ft)\\.?\\s+([^\\])]+)[\\])]\\s*$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: candidate.title, range: NSRange(candidate.title.startIndex..., in: candidate.title)),
           let track = Range(match.range(at: 1), in: candidate.title), let credit = Range(match.range(at: 2), in: candidate.title) {
            values.append(.init(title: String(candidate.title[track]).trimmingCharacters(in: .whitespacesAndNewlines),
                artist: candidate.artist + " feat. " + String(candidate.title[credit])))
        }
        return values
    }

    static func decision(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata) -> LyricsIdentityDecision {
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(kind: .rejected, score: 0, reason: .missingMetadata, hypothesisID: nil)
        }
        guard !candidate.lyrics.lines.isEmpty else {
            return .init(kind: .rejected, score: 0, reason: .emptyContent, hypothesisID: nil)
        }
        var best: LyricsIdentityDecision?
        // Later literal/role probes must not overwrite the derived identity's rejection.
        var rejection: LyricsLookupDiagnostics.Reason?
        for view in candidateViews(candidate) {
        let title = metadata.context.hasYouTubeOrigin
            ? LyricsLookupMetadata.strippingVideoPresentation(LyricsCanonicalMetadata.presentationTitle(view.title)) : view.title
        for hypothesis in metadata.hypotheses {
            let identity: (String) -> String = { performerIdentity($0, hypothesis: hypothesis, video: metadata.context.hasYouTubeOrigin) }
            let expectedTokens = LyricsCanonicalMetadata.tokens(hypothesis.pair.artist).map(identity)
            let actualTokens = LyricsCanonicalMetadata.tokens(view.artist).map(identity)
            guard !actualTokens.isEmpty else { rejection = rejection ?? .missingMetadata; continue }
            let expected = Set(expectedTokens), actual = Set(actualTokens)
            var manual = !hypothesis.allowsAutomaticSelection
            var manualReason: LyricsLookupDiagnostics.Reason? = manual ? .identityConfirmationRequired : nil
            if !expected.isEmpty {
                // Co-equal credits use complete sets. Ordered main/feat credits
                // still require the supplied primary; overlap is never full identity.
                if hasOrderedCredit(hypothesis.pair.artist), expectedTokens.first != actualTokens.first {
                    rejection = rejection ?? .primaryPerformerMismatch; continue
                }
                guard actual.isSubset(of: expected) else {
                    rejection = rejection ?? (actualTokens.first.map { expected.contains($0) } == true ? .guestMismatch : .primaryPerformerMismatch)
                    continue
                }
                if expected != actual {
                    guard expectedTokens.first == actualTokens.first else {
                        rejection = rejection ?? .primaryPerformerMismatch; continue
                    }
                    manual = true; manualReason = .guestMismatch
                } else if !hasOrderedCredit(hypothesis.pair.artist), hasOrderedCredit(view.artist) {
                    manual = true; manualReason = .identityConfirmationRequired
                }
            } else {
                manual = true; manualReason = .identityConfirmationRequired
            }
            let titleTags = LyricsCanonicalMetadata.versions(title)
            let expectedTags = LyricsCanonicalMetadata.versions(hypothesis.pair.title)
            guard titleTags == expectedTags else { rejection = rejection ?? .versionMismatch; continue }
            guard hypothesis.titleVariants.contains(where: {
                LyricsLookupMetadata.identityKey($0) == LyricsLookupMetadata.identityKey(title)
            }) else { rejection = rejection ?? .titleMismatch; continue }
            let albumTags = candidate.album.map(LyricsCanonicalMetadata.versions) ?? []
            let sourceAlbumTags = metadata.context.album.map(LyricsCanonicalMetadata.versions) ?? []
            let sourceVersions = expectedTags.union(sourceAlbumTags)
            if !albumTags.isSubset(of: sourceVersions) {
                // Untagged metadata is not proof of studio. Expose album-only
                // evidence as a related choice, never silently auto-pair it.
                if !sourceVersions.isEmpty { rejection = rejection ?? .versionMismatch; continue }
                manual = true; manualReason = .versionMismatch
            } else if !sourceAlbumTags.isEmpty && albumTags.isEmpty && titleTags.isEmpty {
                manual = true; manualReason = .identityConfirmationRequired
            }
            var score = LyricsLookupMetadata.normalized(candidate.title) == LyricsLookupMetadata.normalized(metadata.originalTitle) ? 40 : 35
            if !expected.isEmpty { score += 30 }
            if let album = candidate.album, let original = metadata.context.album,
               !original.isEmpty, LyricsLookupMetadata.identityKey(album) == LyricsLookupMetadata.identityKey(original) { score += 10 }
            score += 20
            if manual { score = min(score, 84) }
            let result = LyricsIdentityDecision(kind: manual ? .relatedManual : .confirmed,
                score: score, reason: manualReason, hypothesisID: hypothesis.id)
            if best == nil || result.score > best!.score { best = result }
        }
        }
        return best ?? .init(kind: .rejected, score: 0, reason: rejection ?? .identityMismatch, hypothesisID: nil)
    }
}
