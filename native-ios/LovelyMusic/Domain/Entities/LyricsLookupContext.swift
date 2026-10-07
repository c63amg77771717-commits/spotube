import Foundation

/// Original song metadata is retained; query normalization never rewrites the library.
struct LyricsLookupContext: Sendable {
    let songID: String?
    let diagnosticLookupID: String
    let title: String
    let artist: String
    let artistNameSource: SongArtistNameSource?
    let album: String?
    let duration: Int?
    let artistID: String?
    let albumID: String?
    let hasYouTubeOrigin: Bool
    let musicVideoType: String?
    let includeDurationInQuery: Bool

    init(songID: String? = nil, title: String, artist: String, album: String? = nil,
         duration: Int? = nil, artistID: String? = nil, albumID: String? = nil,
         hasYouTubeOrigin: Bool = false, musicVideoType: String? = nil, artistNameSource: SongArtistNameSource? = nil, diagnosticLookupID: String = UUID().uuidString, includeDurationInQuery: Bool = true) {
        self.includeDurationInQuery = includeDurationInQuery
        self.diagnosticLookupID = diagnosticLookupID
        self.songID = songID; self.title = title; self.artist = artist; self.album = album
        self.duration = LyricsMatchingPolicy.validDuration(duration)
        self.artistID = artistID; self.albumID = albumID
        self.hasYouTubeOrigin = hasYouTubeOrigin; self.musicVideoType = musicVideoType
        self.artistNameSource = artistNameSource
    }

    init(song: Song, includeDurationInQuery: Bool = true) {
        self.init(songID: song.id, title: song.title, artist: song.artistName, album: song.albumName,
                  duration: song.duration, artistID: song.artistId, albumID: song.albumId,
                  hasYouTubeOrigin: song.hasYouTubeOrigin && !song.isEpisode && song.id.utf8.allSatisfy { $0 < 128 },
                  musicVideoType: song.musicVideoType, artistNameSource: song.artistNameSource, includeDurationInQuery: includeDurationInQuery)
    }

    var legacySelectionKey: String { LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration) }
    var selectionKey: String {
        guard let songID, !songID.isEmpty else { return legacySelectionKey }
        return "song:" + songID
    }
}

struct LyricsCanonicalMetadata {
    let originalTitle: String
    let originalArtist: String
    let pair: LyricsLookupMetadata.Pair
    let artistTokens: [String]
    let versionTags: Set<String>
    let context: LyricsLookupContext
    let presentationContext: [String]

    init?(_ context: LyricsLookupContext) {
        let title = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = context.artistNameSource == .uploader ? "" : context.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let cleaned = ChineseLyricsMetadataCleaner.analyze(context)
        var pair = cleaned.pair
        if pair.artist.isEmpty {
            guard context.hasYouTubeOrigin else { return nil }
        }
        if context.hasYouTubeOrigin { pair = .init(title: Self.presentationTitle(pair.title), artist: pair.artist) }
        guard !pair.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.context = context; originalTitle = title; originalArtist = artist; self.pair = pair
        presentationContext = cleaned.presentationContext
        artistTokens = Self.tokens(pair.artist); versionTags = Self.versions(pair.title)
    }

    /// Explicit bracket or dash credits can establish bounded bilingual title variants.
    /// Version words are never aliases and bare titles are never split into words.
    var explicitTitleVariants: [String] {
        ChineseLyricsMetadataCleaner.titleVariants(pair.title, context: context)
    }

    func matchesTitle(_ title: String) -> Bool {
        explicitTitleVariants.contains { LyricsLookupMetadata.identityKey($0) == LyricsLookupMetadata.identityKey(title) }
    }

    var alternateVideoPair: LyricsLookupMetadata.Pair? {
        let pairs = LyricsLookupMetadata.videoCreditPairs(context)
        guard pairs.count == 2 else { return nil }
        return pairs.first {
            LyricsLookupMetadata.identityKey($0.title) != LyricsLookupMetadata.identityKey(pair.title)
                || LyricsLookupMetadata.identityKey($0.artist) != LyricsLookupMetadata.identityKey(pair.artist)
        }
    }

    var quotedVideoPair: LyricsLookupMetadata.Pair? {
        guard let quoted = LyricsLookupMetadata.quotedVideoPair(context),
              LyricsLookupMetadata.identityKey(quoted.title) != LyricsLookupMetadata.identityKey(pair.title) else { return nil }
        return quoted
    }

    var hypotheses: [LyricsIdentityHypothesis] { LyricsIdentityPolicy.hypotheses(self) }

    var requiresManualIdentityConfirmation: Bool {
        hypotheses.first?.allowsAutomaticSelection != true
    }

    var alternativePairs: [LyricsLookupMetadata.Pair] {
        [alternateVideoPair, quotedVideoPair].compactMap { $0 }
    }

    /// Remove only entire standalone labels. Mixed brackets such as (Live Official MV) survive.
    static func presentationTitle(_ title: String) -> String {
        let label = "(?:official\\s+(?:music\\s+video|video|audio|mv|lyrics?\\s+video)|music\\s+video|lyrics?\\s+video|official\\s+lyrics?|官方\\s*(?:mv|音樂錄影帶|音乐录影带|歌詞影片|歌词影片)|4k|hd|visualizer)"
        let suffix = "(?i)(?:\\s*\\(\\s*\(label)\\s*\\)|\\s*\\[\\s*\(label)\\s*\\]|\\s*【\\s*\(label)\\s*】|\\s+\(label))\\s*$"
        var value = title
        while let range = value.range(of: suffix, options: .regularExpression) {
            let preceding = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preceding.isEmpty, !LyricsLookupMetadata.normalized(preceding).hasSuffix("unofficial") else { break }
            value = preceding
        }
        return value
    }

    static func creditComponents(_ artist: String) -> [String] {
        let separated = artist
            .replacingOccurrences(of: "(?i)\\b(?:feat(?:uring)?|ft|with)\\.?\\s+", with: "|", options: .regularExpression)
            .replacingOccurrences(of: "\\s+x\\s+", with: "|", options: .regularExpression)
        return separated.components(separatedBy: CharacterSet(charactersIn: "&+×/,、|;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func tokens(_ artist: String) -> [String] {
        creditComponents(artist).map(LyricsLookupMetadata.identityKey)
    }

    /// Bilingual equivalents come only from this verified video's explicit credit.
    /// Never infer unrelated aliases or reorder the primary performer.
    private var bilingualCredits: [[String]] {
        guard context.hasYouTubeOrigin else { return [] }
        let pattern = "^([\\p{Han}]{2,})\\s+([A-Za-z][A-Za-z .'-]*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Self.creditComponents(pair.artist).map { credit in
            guard let match = regex.firstMatch(in: credit, range: NSRange(credit.startIndex..., in: credit)),
                  let han = Range(match.range(at: 1), in: credit),
                  let latin = Range(match.range(at: 2), in: credit) else { return [credit] }
            return [credit, String(credit[han]), String(credit[latin])]
        }
    }

    func performerIdentity(_ token: String) -> String {
        for group in bilingualCredits {
            let keys = group.map(LyricsLookupMetadata.identityKey)
            if keys.contains(token) { return Self.artistIdentity(keys[0]) }
        }
        return Self.artistIdentity(token)
    }

    var explicitArtistVariants: [String] {
        let credits = bilingualCredits
        guard credits.contains(where: { $0.count == 3 }) else { return [] }
        return [1, 2].map { index in credits.map { $0.count == 3 ? $0[index] : $0[0] }.joined(separator: " & ") }
    }

    // Explicit, curated equivalence only; no transliteration guesses or remote metadata service.
    static let aliasGroups = [["周杰倫", "周杰伦", "Jay Chou", "周杰倫 Jay Chou"],
                              ["五月天", "Mayday", "五月天 Mayday"]]
    static func artistIdentity(_ token: String) -> String {
        for group in aliasGroups {
            if group.map(LyricsLookupMetadata.identityKey).contains(token) { return LyricsLookupMetadata.identityKey(group[0]) }
        }
        return token
    }
    static func alternateArtist(_ artist: String) -> String? {
        let key = LyricsLookupMetadata.identityKey(artist)
        guard let group = aliasGroups.first(where: { $0.map(LyricsLookupMetadata.identityKey).contains(key) }) else { return nil }
        return group.first { LyricsLookupMetadata.identityKey($0) != key }
    }

    static func versions(_ title: String) -> Set<String> {
        let patterns: [(String, String)] = [
            ("live", "\\blive(?:\\s+session)?(?=\\b|版|影音)|現場|现场|演唱會|演唱会|\\bconcert\\b"),
            ("remix", "\\bremix\\b"), ("acoustic", "\\bacoustic\\b"), ("cover", "\\bcover\\b|翻唱"),
            ("instrumental", "\\binstrumental\\b|伴奏"), ("karaoke", "\\bkaraoke\\b"), ("demo", "\\bdemo\\b"),
            ("remastered", "\\bremaster(?:ed)?\\b"), ("spedup", "\\bsped\\s*up\\b|加速"),
            ("slowed", "\\bslowed\\b|慢速"), ("nightcore", "\\bnightcore\\b"),
            ("radioedit", "\\bradio\\s+edit\\b"), ("extended", "\\bextended\\b"),
            ("originalmix", "\\boriginal\\s+mix\\b"), ("edit", "\\bedit\\b"), ("version", "\\bversion\\b")]
        return Set(patterns.compactMap { tag, pattern in
            title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : tag
        })
    }
}

enum LyricsQueryPlanner {
    struct Query {
        let endpoint: String
        let pair: LyricsLookupMetadata.Pair
        let duration: Int?
    }
    /// At most six metadata requests per provider, excluding one remembered-record read.
    static func queries(_ metadata: LyricsCanonicalMetadata) -> [Query] {
        let original = LyricsLookupMetadata.Pair(title: metadata.originalTitle, artist: metadata.originalArtist)
        var queries: [Query] = []
        if !original.artist.isEmpty {
            if metadata.context.includeDurationInQuery, let duration = metadata.context.duration { queries.append(.init(endpoint: "get", pair: original, duration: duration)) }
            queries.append(.init(endpoint: "get", pair: original, duration: nil))
        }
        let titles = metadata.explicitTitleVariants
        let primaryTitle = titles.first { $0.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) } } ?? metadata.pair.title
        let artists = metadata.explicitArtistVariants
        let strongest = LyricsLookupMetadata.Pair(title: primaryTitle, artist: artists.first ?? metadata.pair.artist)
        // Strong complete role/alias combinations precede weaker reverse/literal probes.
        queries.append(.init(endpoint: "search", pair: strongest, duration: nil))
        if metadata.pair.title != strongest.title || metadata.pair.artist != strongest.artist {
            queries.append(.init(endpoint: "search", pair: metadata.pair, duration: nil))
        }
        if let latin = artists.last, artists.count > 1 {
            queries.append(.init(endpoint: "search", pair: .init(title: primaryTitle, artist: latin), duration: nil))
            if let aliasTitle = titles.last, aliasTitle != primaryTitle {
                queries.append(.init(endpoint: "search", pair: .init(title: aliasTitle, artist: latin), duration: nil))
            }
        }
        if let simplified = LyricsLookupMetadata.simplifiedPair(strongest) {
            queries.append(.init(endpoint: "search", pair: simplified, duration: nil))
        } else {
            let title = strongest.title.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? strongest.title
            let artist = strongest.artist.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? strongest.artist
            if title != strongest.title || artist != strongest.artist {
                queries.append(.init(endpoint: "search", pair: .init(title: title, artist: artist), duration: nil))
            }
        }
        if let alias = LyricsCanonicalMetadata.alternateArtist(strongest.artist) {
            queries.append(.init(endpoint: "search", pair: .init(title: primaryTitle, artist: alias), duration: nil))
        }
        for hypothesis in metadata.hypotheses {
            for title in hypothesis.titleVariants {
                queries.append(.init(endpoint: "search", pair: .init(title: title, artist: hypothesis.pair.artist), duration: nil))
            }
        }
        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0.endpoint + "|" + $0.pair.title + "|" + $0.pair.artist + "|" + String($0.duration ?? 0)).inserted }.prefix(6))
    }

    static func secondaryPairs(_ metadata: LyricsCanonicalMetadata) -> [LyricsLookupMetadata.Pair] {
        var seen = Set<String>()
        let planned = queries(metadata)
        let pairs = planned.filter { $0.endpoint == "search" }.map(\.pair) + planned.map(\.pair)
        return Array(pairs.filter {
            seen.insert($0.title + "|" + $0.artist).inserted
        }.prefix(6))
    }

}

enum LyricsCandidateScorer {
    static func decision(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata,
                         remembered: LyricsRecordID? = nil) -> LyricsIdentityDecision {
        LyricsIdentityPolicy.decision(candidate, metadata: metadata, remembered: remembered)
    }

    static func score(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata) -> Int? {
        let result = decision(candidate, metadata: metadata)
        return result.kind == .rejected ? nil : result.score
    }

    static func rejectionReason(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata) -> LyricsLookupDiagnostics.Reason {
        decision(candidate, metadata: metadata).reason ?? .identityMismatch
    }

    static func remembered(_ context: LyricsLookupContext, defaults: UserDefaults) -> LyricsRecordID? {
        LyricsSelectionStore.selectedRecord(for: context.selectionKey, defaults: defaults)
            ?? LyricsSelectionStore.selectedRecord(for: context.legacySelectionKey, defaults: defaults)
    }

    static func choose(_ candidates: [LyricsCandidate], metadata: LyricsCanonicalMetadata,
                       defaults: UserDefaults, failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var accepted: [LyricsRecordID: (LyricsCandidate, Int)] = [:]
        for rawCandidate in candidates {
            let identity = decision(rawCandidate, metadata: metadata, remembered: remembered(metadata.context, defaults: defaults))
            guard identity.kind != .rejected else {
                LyricsLookupDiagnostics.shared.record(.init(context: metadata.context, provider: rawCandidate.providerID,
                    phase: .candidateDropped, reason: rejectionReason(rawCandidate, metadata: metadata),
                    title: rawCandidate.title, artist: rawCandidate.artist, duration: rawCandidate.duration, recordID: rawCandidate.recordID))
                continue
            }
            let score = identity.score
            let candidate = rawCandidate.withIdentityDecision(identity)
            let timingReason: LyricsLookupDiagnostics.Reason?
            switch candidate.lyrics.timingState {
            case .structurallyCompatible: timingReason = nil
            case .timingUnknown: timingReason = .timingUnknown
            case .durationMismatch: timingReason = .durationMismatch
            case .invalidTimestamp: timingReason = .invalidTimestamp
            case .unsupportedTiming: timingReason = .unsupportedTiming
            case .plainOnly: timingReason = .plainOnly
            }
            LyricsLookupDiagnostics.shared.record(.init(context: metadata.context, provider: candidate.providerID,
                phase: .candidateAccepted, reason: timingReason, title: candidate.title, artist: candidate.artist,
                duration: candidate.duration, recordID: candidate.recordID, score: score, hypothesisID: identity.hypothesisID))
            // Rejected identities never reserve an ID. Keep the stronger complete record,
            // including newly verified timestamps, without merging different timelines.
            if let previous = accepted[candidate.id],
               previous.1 > score || (previous.1 == score && (previous.0.lyrics.isTimeSynced || !candidate.lyrics.isTimeSynced)) {
                continue
            }
            accepted[candidate.id] = (candidate, score)
        }
        let ranked = accepted.values.sorted { $0.1 == $1.1 ? $0.0.id.providerID.rawValue + $0.0.id.recordID < $1.0.id.providerID.rawValue + $1.0.id.recordID : $0.1 > $1.1 }
        guard let best = ranked.first else {
            LyricsLookupDiagnostics.shared.record(.init(context: metadata.context, phase: .result,
                reason: candidates.isEmpty ? .noUsableCandidate : .allCandidatesRejected, count: 0))
            return nil
        }
        let saved = remembered(metadata.context, defaults: defaults).flatMap { id in ranked.first { $0.0.id == id }?.0 }
        if let saved, metadata.context.selectionKey != metadata.context.legacySelectionKey {
            LyricsSelectionStore.select(saved.id, for: metadata.context.selectionKey, defaults: defaults)
        }
        let uniqueHigh = best.1 >= 85 && (ranked.count == 1 || best.1 - ranked[1].1 >= 10)
        let chosen = saved ?? (best.0.identityDecision?.allowsAutomaticSelection == true && uniqueHigh ? best.0 : nil)
        LyricsLookupDiagnostics.shared.record(.init(context: metadata.context, provider: chosen?.providerID,
            phase: .selection, reason: saved != nil ? .rememberedSelected : chosen != nil ? .autoSelected : .manualRequired,
            recordID: chosen?.recordID, count: ranked.count, score: best.1))
        return SyncedLyrics(lines: chosen?.lyrics.lines ?? [], source: chosen?.lyrics.source ?? "",
                            isTimeSynced: chosen?.lyrics.isTimeSynced ?? false, candidates: ranked.map { $0.0 },
                            selectionKey: metadata.context.selectionKey, providerID: chosen?.providerID, sourceFailures: failures,
                            timingState: chosen?.lyrics.timingState)
    }
}
