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
    let scoreBreakdown: [String: Int]
    init(kind: Kind, score: Int, reason: LyricsLookupDiagnostics.Reason?, hypothesisID: String?, scoreBreakdown: [String: Int] = [:]) {
        self.kind = kind; self.score = score; self.reason = reason; self.hypothesisID = hypothesisID
        self.scoreBreakdown = scoreBreakdown
    }
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
            values.append(.init(id: "alternative-" + String(index), pair: pair,
                titleVariants: ChineseLyricsMetadataCleaner.titleVariants(pair.title, context: context),
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
        artist.range(of: LyricsCanonicalMetadata.orderedCreditSeparatorPattern, options: .regularExpression) != nil
    }

    private struct CandidateView { let title: String; let artist: String }
    private static func candidateViews(_ candidate: LyricsCandidate) -> [CandidateView] {
        var values = [CandidateView(title: candidate.title, artist: candidate.artist)]
        // A complete trailing feat credit can supplement performer metadata.
        // The literal title remains available; arbitrary bracket subtitles survive.
        let patterns = [
            "(?i)^(.+?)\\s*\\(\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()]+)\\)\\s*$",
            "(?i)^(.+?)\\s*\\[\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()]+)\\]\\s*$"
        ]
        for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: candidate.title, range: NSRange(candidate.title.startIndex..., in: candidate.title)),
           let track = Range(match.range(at: 1), in: candidate.title), let credit = Range(match.range(at: 2), in: candidate.title) {
            values.append(.init(title: String(candidate.title[track]).trimmingCharacters(in: .whitespacesAndNewlines),
                artist: candidate.artist + " feat. " + String(candidate.title[credit])))
        }
        }
        return values
    }

    /// Complete source/candidate field agreement before any score can remove a
    /// direction cap. Provider metadata does not invent missing source credits.
    static func hasCompleteDirectionIdentity(_ candidate: LyricsCandidate, hypothesis: LyricsIdentityHypothesis,
                                             metadata: LyricsCanonicalMetadata) -> Bool {
        guard !candidate.lyrics.lines.isEmpty else { return false }
        let identity: (String) -> String = { performerIdentity($0, hypothesis: hypothesis, video: metadata.context.hasYouTubeOrigin) }
        let expectedTokens = LyricsCanonicalMetadata.tokens(hypothesis.pair.artist).map(identity)
        let expected = Set(expectedTokens)
        guard !expected.isEmpty, expected.count == expectedTokens.count else { return false }
        for view in candidateViews(candidate) {
            let title = metadata.context.hasYouTubeOrigin
                ? LyricsLookupMetadata.strippingVideoPresentation(LyricsCanonicalMetadata.presentationTitle(view.title)) : view.title
            let actualTokens = LyricsCanonicalMetadata.tokens(view.artist).map(identity)
            guard expected == Set(actualTokens), actualTokens.count == expected.count,
                  hasOrderedCredit(hypothesis.pair.artist) == hasOrderedCredit(view.artist),
                  !hasOrderedCredit(hypothesis.pair.artist) || expectedTokens.first == actualTokens.first,
                  hypothesis.titleVariants.contains(where: { LyricsLookupMetadata.identityKey($0) == LyricsLookupMetadata.identityKey(title) }),
                  LyricsCanonicalMetadata.versions(title) == LyricsCanonicalMetadata.versions(hypothesis.pair.title) else { continue }
            let sourceVersions = LyricsCanonicalMetadata.versions(hypothesis.pair.title)
                .union(metadata.context.album.map(LyricsCanonicalMetadata.versions) ?? [])
            guard (candidate.album.map(LyricsCanonicalMetadata.versions) ?? []).isSubset(of: sourceVersions) else { continue }
            return true
        }
        return false
    }

    static func durationPoints(recording: Double?, video: Int?) -> Int {
        guard let recording, recording.isFinite, recording > 0, recording <= 86400,
              let video, video > 0 else { return 0 }
        let difference = abs(recording - Double(video))
        if difference <= 2 { return 20 }
        if difference <= 5 { return 15 }
        if difference <= 10 { return 8 }
        return 0
    }

    private static func narrowlyDifferentHanPerformer(_ expected: String, _ actual: String) -> Bool {
        let left = Array(expected), right = Array(actual)
        guard left.count == right.count, (3...4).contains(left.count), left.first == right.first,
              (expected + actual).unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) else { return false }
        return zip(left, right).filter { $0.0 != $0.1 }.count == 1
    }

    static func decision(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata,
                         remembered: LyricsRecordID? = nil, confirmedDirectionIDs: Set<String> = []) -> LyricsIdentityDecision {
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(kind: .rejected, score: 0, reason: .missingMetadata, hypothesisID: nil)
        }
        guard !candidate.lyrics.lines.isEmpty else {
            return .init(kind: .rejected, score: 0, reason: .emptyContent, hypothesisID: nil)
        }
        var best: LyricsIdentityDecision?
        var scoredRejection: LyricsIdentityDecision?
        // Later literal/role probes must not overwrite the derived identity's rejection.
        var rejection: LyricsLookupDiagnostics.Reason?
        for view in candidateViews(candidate) {
        let title = metadata.context.hasYouTubeOrigin
            ? LyricsLookupMetadata.strippingVideoPresentation(LyricsCanonicalMetadata.presentationTitle(view.title)) : view.title
        for hypothesis in metadata.hypotheses {
            let identity: (String) -> String = { performerIdentity($0, hypothesis: hypothesis, video: metadata.context.hasYouTubeOrigin) }
            let duetCredits = LyricsLookupMetadata.corroboratedDuetCredits(context: metadata.context, pair: hypothesis.pair, returnedArtist: view.artist)
            let expectedTokens = duetCredits.map { $0.map(LyricsLookupMetadata.identityKey).map(identity) }
                ?? LyricsCanonicalMetadata.tokens(hypothesis.pair.artist).map(identity)
            let actualTokens = LyricsCanonicalMetadata.tokens(view.artist).map(identity)
            guard !actualTokens.isEmpty else { rejection = rejection ?? .missingMetadata; continue }
            var expected = Set(expectedTokens)
            let actual = Set(actualTokens)
            let directionConfirmed = confirmedDirectionIDs.contains(hypothesis.id)
                && hasCompleteDirectionIdentity(candidate, hypothesis: hypothesis, metadata: metadata)
            var manual = (!hypothesis.allowsAutomaticSelection && !directionConfirmed) || duetCredits != nil
            var manualReason: LyricsLookupDiagnostics.Reason? = manual ? .identityConfirmationRequired : nil
            let titleMatches = hypothesis.titleVariants.contains {
                LyricsLookupMetadata.identityKey($0) == LyricsLookupMetadata.identityKey(title)
            }
            var spellingUncertain = false
            if let primary = expectedTokens.first, let returned = actualTokens.first,
               primary != returned, titleMatches,
               durationPoints(recording: candidate.duration, video: metadata.context.duration) >= 15,
               narrowlyDifferentHanPerformer(primary, returned) {
                // A single character difference is not an alias or a confirmed identity.
                expected.remove(primary); expected.insert(returned)
                spellingUncertain = true; manual = true; manualReason = .artistSpellingUncertain
            }
            if !expected.isEmpty {
                // Co-equal credits use complete sets. Ordered main/feat credits
                // still require the supplied primary; overlap is never full identity.
                if hasOrderedCredit(hypothesis.pair.artist), !spellingUncertain, expectedTokens.first != actualTokens.first {
                    rejection = rejection ?? .primaryPerformerMismatch; continue
                }
                guard actual.isSubset(of: expected) else {
                    rejection = rejection ?? (actualTokens.first.map { expected.contains($0) } == true ? .guestMismatch : .primaryPerformerMismatch)
                    continue
                }
                if expected != actual {
                    guard spellingUncertain || expectedTokens.first == actualTokens.first else {
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
            guard titleMatches else { rejection = rejection ?? .titleMismatch; continue }
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
            let titleKey = LyricsLookupMetadata.identityKey(title)
            let primaryTitle = hypothesis.titleVariants.first { $0.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) } }
                ?? hypothesis.pair.title
            let primaryCredits = LyricsCanonicalMetadata.creditComponents(hypothesis.pair.artist).map {
                ChineseLyricsMetadataCleaner.primaryHanCredit($0) ?? $0
            }
            let primaryCreditTokens = Set(primaryCredits.map(LyricsLookupMetadata.identityKey))
            let returnedCreditTokens = Set(LyricsCanonicalMetadata.tokens(view.artist))
            let artistPoints = expected.isEmpty ? 0 : spellingUncertain ? 10
                : primaryCreditTokens == returnedCreditTokens
                    || Set(LyricsCanonicalMetadata.tokens(hypothesis.pair.artist)) == returnedCreditTokens ? 35
                    : expected == actual ? 20 : 10
            let titlePoints = titleKey == LyricsLookupMetadata.identityKey(primaryTitle)
                ? (primaryTitle.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } ? 45 : 40)
                : titleKey == LyricsLookupMetadata.identityKey(hypothesis.pair.title) ? 40 : 10
            let albumKey = candidate.album.map(LyricsLookupMetadata.identityKey)
            let sourceAlbumKey = metadata.context.album.map(LyricsLookupMetadata.identityKey)
            let weakContext = albumKey.map { key in
                guard !key.isEmpty else { return false }
                return metadata.presentationContext.contains {
                    let workKey = LyricsLookupMetadata.identityKey($0)
                    return !workKey.isEmpty && key.contains(workKey)
                } || sourceAlbumKey.map { !$0.isEmpty && $0 == key } == true
            } ?? false
            // Exactly one contribution per field. Identity/version gates above cannot be rescued by duration.
            var components = ["title": titlePoints, "artist": artistPoints,
                "duration": durationPoints(recording: candidate.duration, video: metadata.context.duration),
                "weakContext": weakContext ? 5 : 0, "rememberedRecord": remembered == candidate.id ? 10 : 0]
            var score = components.values.reduce(0, +)
            guard score >= 65 else {
                let result = LyricsIdentityDecision(kind: .rejected, score: score, reason: .scoreBelowManual,
                    hypothesisID: hypothesis.id, scoreBreakdown: components)
                if scoredRejection == nil || score > scoredRejection!.score { scoredRejection = result }
                rejection = rejection ?? .scoreBelowManual; continue
            }
            if score < 85 { manual = true; manualReason = manualReason ?? .identityConfirmationRequired }
            if manual {
                let capped = min(score, 84); components["confidenceCap"] = capped - score; score = capped
            }
            let result = LyricsIdentityDecision(kind: manual ? .relatedManual : .confirmed,
                score: score, reason: manualReason, hypothesisID: hypothesis.id, scoreBreakdown: components)
            if best == nil || result.score > best!.score { best = result }
        }
        }
        return best ?? scoredRejection ?? .init(kind: .rejected, score: 0, reason: rejection ?? .identityMismatch, hypothesisID: nil)
    }
}
