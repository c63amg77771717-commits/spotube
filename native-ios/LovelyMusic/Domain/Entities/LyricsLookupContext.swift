import Foundation

/// Original song metadata is retained; query normalization never rewrites the library.
struct LyricsLookupContext: Sendable {
    let songID: String?
    let title: String
    let artist: String
    let album: String?
    let duration: Int?
    let artistID: String?
    let albumID: String?
    let hasYouTubeOrigin: Bool
    let musicVideoType: String?

    init(songID: String? = nil, title: String, artist: String, album: String? = nil,
         duration: Int? = nil, artistID: String? = nil, albumID: String? = nil,
         hasYouTubeOrigin: Bool = false, musicVideoType: String? = nil) {
        self.songID = songID; self.title = title; self.artist = artist; self.album = album
        self.duration = LyricsMatchingPolicy.validDuration(duration)
        self.artistID = artistID; self.albumID = albumID
        self.hasYouTubeOrigin = hasYouTubeOrigin; self.musicVideoType = musicVideoType
    }

    init(song: Song) {
        self.init(songID: song.id, title: song.title, artist: song.artistName, album: song.albumName,
                  duration: song.duration, artistID: song.artistId, albumID: song.albumId,
                  hasYouTubeOrigin: song.hasYouTubeOrigin && !song.isEpisode && song.id.utf8.allSatisfy { $0 < 128 },
                  musicVideoType: song.musicVideoType)
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

    init?(_ context: LyricsLookupContext) {
        let title = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = context.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var pair = LyricsLookupMetadata.Pair(title: title, artist: artist)
        if let clean = LyricsLookupMetadata.cleaned(title: title, artist: artist, allowVideoCredits: context.hasYouTubeOrigin) {
            pair = clean
        }
        if pair.artist.isEmpty {
            guard context.hasYouTubeOrigin, !title.contains(" - "), !title.contains("《"), !title.contains("【") else { return nil }
        }
        if context.hasYouTubeOrigin { pair = .init(title: Self.presentationTitle(pair.title), artist: pair.artist) }
        self.context = context; originalTitle = title; originalArtist = artist; self.pair = pair
        artistTokens = Self.tokens(pair.artist); versionTags = Self.versions(pair.title)
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

    static func tokens(_ artist: String) -> [String] {
        let separated = artist.replacingOccurrences(of: "(?i)\\b(?:feat(?:uring)?|ft|with)\\.?\\s+", with: "|", options: .regularExpression)
        return separated.components(separatedBy: CharacterSet(charactersIn: "&+×/,、|;；"))
            .map { LyricsLookupMetadata.identityKey($0) }.filter { !$0.isEmpty }
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
            ("live", "\\blive(?:\\s+session)?\\b|現場|现场|演唱會|演唱会|\\bconcert\\b"),
            ("remix", "\\bremix\\b"), ("acoustic", "\\bacoustic\\b"), ("cover", "\\bcover\\b|翻唱"),
            ("instrumental", "\\binstrumental\\b"), ("karaoke", "\\bkaraoke\\b"), ("demo", "\\bdemo\\b"),
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
            if let duration = metadata.context.duration { queries.append(.init(endpoint: "get", pair: original, duration: duration)) }
            queries.append(.init(endpoint: "get", pair: original, duration: nil))
        }
        queries.append(.init(endpoint: "search", pair: metadata.pair, duration: nil))
        if let simplified = LyricsLookupMetadata.simplifiedPair(metadata.pair) {
            queries.append(.init(endpoint: "search", pair: simplified, duration: nil))
        } else {
            let title = metadata.pair.title.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? metadata.pair.title
            let artist = metadata.pair.artist.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? metadata.pair.artist
            if title != metadata.pair.title || artist != metadata.pair.artist {
                queries.append(.init(endpoint: "search", pair: .init(title: title, artist: artist), duration: nil))
            }
        }
        if let alias = LyricsCanonicalMetadata.alternateArtist(metadata.pair.artist) {
            queries.append(.init(endpoint: "search", pair: .init(title: metadata.pair.title, artist: alias), duration: nil))
        }
        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0.endpoint + "|" + $0.pair.title + "|" + $0.pair.artist + "|" + String($0.duration ?? 0)).inserted }.prefix(6))
    }

    static func secondaryPairs(_ metadata: LyricsCanonicalMetadata) -> [LyricsLookupMetadata.Pair] {
        var seen = Set<String>()
        let original = LyricsLookupMetadata.Pair(title: metadata.originalTitle, artist: metadata.originalArtist)
        return Array(([original, metadata.pair] + queries(metadata).map(\.pair))
            .filter { seen.insert($0.title + "|" + $0.artist).inserted && (!$0.artist.isEmpty || metadata.pair.artist.isEmpty) }.prefix(6))
    }
}

enum LyricsCandidateScorer {
    static func score(_ candidate: LyricsCandidate, metadata: LyricsCanonicalMetadata) -> Int? {
        let title = metadata.context.hasYouTubeOrigin ? LyricsCanonicalMetadata.presentationTitle(candidate.title) : candidate.title
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LyricsCanonicalMetadata.versions(title) == metadata.versionTags,
              LyricsLookupMetadata.identityKey(title) == LyricsLookupMetadata.identityKey(metadata.pair.title) else { return nil }
        var score = LyricsLookupMetadata.normalized(candidate.title) == LyricsLookupMetadata.normalized(metadata.originalTitle) ? 40 : 35
        let tokens = LyricsCanonicalMetadata.tokens(candidate.artist)
        if let primary = metadata.artistTokens.first {
            guard let otherPrimary = tokens.first,
                  LyricsCanonicalMetadata.artistIdentity(primary) == LyricsCanonicalMetadata.artistIdentity(otherPrimary) else { return nil }
            let expected = Set(metadata.artistTokens.map(LyricsCanonicalMetadata.artistIdentity))
            let actual = Set(tokens.map(LyricsCanonicalMetadata.artistIdentity))
            // A different credited guest changes recording identity; incomplete credits are manual.
            guard actual.isSubset(of: expected) || expected.isSubset(of: actual) else { return nil }
            if LyricsLookupMetadata.normalized(candidate.artist) == LyricsLookupMetadata.normalized(metadata.pair.artist) { score += 30 }
            else if Set(tokens) == Set(metadata.artistTokens) { score += 25 }
            else if expected == actual { score += 20 }
            else { return min(score + 40, 84) }
        }
        if let album = candidate.album, let expected = metadata.context.album,
           !expected.isEmpty, LyricsLookupMetadata.identityKey(album) == LyricsLookupMetadata.identityKey(expected) { score += 10 }
        if let duration = candidate.duration, duration.isFinite, duration > 0, let expected = metadata.context.duration {
            let delta = abs(duration - Double(expected))
            score += delta <= 2 ? 15 : delta <= 5 ? 10 : delta <= 10 ? 5 : 0
        }
        score += 20 // Exact version set, including an explicitly untagged studio recording.
        return score
    }

    static func remembered(_ context: LyricsLookupContext, defaults: UserDefaults) -> LyricsRecordID? {
        LyricsSelectionStore.selectedRecord(for: context.selectionKey, defaults: defaults)
            ?? LyricsSelectionStore.selectedRecord(for: context.legacySelectionKey, defaults: defaults)
    }

    static func choose(_ candidates: [LyricsCandidate], metadata: LyricsCanonicalMetadata,
                       defaults: UserDefaults, failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var seen = Set<LyricsRecordID>()
        let ranked = candidates.compactMap { candidate -> (LyricsCandidate, Int)? in
            guard seen.insert(candidate.id).inserted, let score = score(candidate, metadata: metadata),
                  score >= 65 || metadata.artistTokens.isEmpty else { return nil }
            return (candidate, score)
        }.sorted { $0.1 == $1.1 ? $0.0.id.providerID.rawValue + $0.0.id.recordID < $1.0.id.providerID.rawValue + $1.0.id.recordID : $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        let saved = remembered(metadata.context, defaults: defaults).flatMap { id in ranked.first { $0.0.id == id }?.0 }
        if let saved, metadata.context.selectionKey != metadata.context.legacySelectionKey {
            LyricsSelectionStore.select(saved.id, for: metadata.context.selectionKey, defaults: defaults)
        }
        let uniqueHigh = best.1 >= 85 && (ranked.count == 1 || best.1 - ranked[1].1 >= 10)
        let chosen = saved ?? (!metadata.artistTokens.isEmpty && uniqueHigh ? best.0 : nil)
        return SyncedLyrics(lines: chosen?.lyrics.lines ?? [], source: chosen?.lyrics.source ?? "",
                            isTimeSynced: chosen?.lyrics.isTimeSynced ?? false, candidates: ranked.map { $0.0 },
                            selectionKey: metadata.context.selectionKey, providerID: chosen?.providerID, sourceFailures: failures)
    }
}
