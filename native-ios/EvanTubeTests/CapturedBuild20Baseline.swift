// Frozen pre-repair Build20 production implementation; renamed only to run beside production.
// Shared domain values and transport have unchanged behavior for these captured requests.
@testable import LovelyMusic
import Foundation

/// Original song metadata is retained; query normalization never rewrites the library.
struct CapturedBuild20LyricsLookupContext: Sendable {
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
        self.duration = CapturedBuild20LyricsMatchingPolicy.validDuration(duration)
        self.artistID = artistID; self.albumID = albumID
        self.hasYouTubeOrigin = hasYouTubeOrigin; self.musicVideoType = musicVideoType
    }

    init(song: Song) {
        self.init(songID: song.id, title: song.title, artist: song.artistName, album: song.albumName,
                  duration: song.duration, artistID: song.artistId, albumID: song.albumId,
                  hasYouTubeOrigin: song.hasYouTubeOrigin && !song.isEpisode && song.id.utf8.allSatisfy { $0 < 128 },
                  musicVideoType: song.musicVideoType)
    }

    var legacySelectionKey: String { CapturedBuild20LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration) }
    var selectionKey: String {
        guard let songID, !songID.isEmpty else { return legacySelectionKey }
        return "song:" + songID
    }
}

struct CapturedBuild20LyricsCanonicalMetadata {
    let originalTitle: String
    let originalArtist: String
    let pair: CapturedBuild20LyricsLookupMetadata.Pair
    let artistTokens: [String]
    let versionTags: Set<String>
    let context: CapturedBuild20LyricsLookupContext

    init?(_ context: CapturedBuild20LyricsLookupContext) {
        let title = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = context.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var pair = CapturedBuild20LyricsLookupMetadata.Pair(title: title, artist: artist)
        if let clean = CapturedBuild20LyricsLookupMetadata.cleaned(title: title, artist: artist, allowVideoCredits: context.hasYouTubeOrigin) {
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
            guard !preceding.isEmpty, !CapturedBuild20LyricsLookupMetadata.normalized(preceding).hasSuffix("unofficial") else { break }
            value = preceding
        }
        return value
    }

    static func tokens(_ artist: String) -> [String] {
        let separated = artist.replacingOccurrences(of: "(?i)\\b(?:feat(?:uring)?|ft|with)\\.?\\s+", with: "|", options: .regularExpression)
        return separated.components(separatedBy: CharacterSet(charactersIn: "&+×/,、|;；"))
            .map { CapturedBuild20LyricsLookupMetadata.identityKey($0) }.filter { !$0.isEmpty }
    }

    // Explicit, curated equivalence only; no transliteration guesses or remote metadata service.
    static let aliasGroups = [["周杰倫", "周杰伦", "Jay Chou", "周杰倫 Jay Chou"],
                              ["五月天", "Mayday", "五月天 Mayday"]]
    static func artistIdentity(_ token: String) -> String {
        for group in aliasGroups {
            if group.map(CapturedBuild20LyricsLookupMetadata.identityKey).contains(token) { return CapturedBuild20LyricsLookupMetadata.identityKey(group[0]) }
        }
        return token
    }
    static func alternateArtist(_ artist: String) -> String? {
        let key = CapturedBuild20LyricsLookupMetadata.identityKey(artist)
        guard let group = aliasGroups.first(where: { $0.map(CapturedBuild20LyricsLookupMetadata.identityKey).contains(key) }) else { return nil }
        return group.first { CapturedBuild20LyricsLookupMetadata.identityKey($0) != key }
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

enum CapturedBuild20LyricsQueryPlanner {
    struct Query {
        let endpoint: String
        let pair: CapturedBuild20LyricsLookupMetadata.Pair
        let duration: Int?
    }
    /// At most six metadata requests per provider, excluding one remembered-record read.
    static func queries(_ metadata: CapturedBuild20LyricsCanonicalMetadata) -> [Query] {
        let original = CapturedBuild20LyricsLookupMetadata.Pair(title: metadata.originalTitle, artist: metadata.originalArtist)
        var queries: [Query] = []
        if !original.artist.isEmpty {
            if let duration = metadata.context.duration { queries.append(.init(endpoint: "get", pair: original, duration: duration)) }
            queries.append(.init(endpoint: "get", pair: original, duration: nil))
        }
        queries.append(.init(endpoint: "search", pair: metadata.pair, duration: nil))
        if let simplified = CapturedBuild20LyricsLookupMetadata.simplifiedPair(metadata.pair) {
            queries.append(.init(endpoint: "search", pair: simplified, duration: nil))
        } else {
            let title = metadata.pair.title.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? metadata.pair.title
            let artist = metadata.pair.artist.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? metadata.pair.artist
            if title != metadata.pair.title || artist != metadata.pair.artist {
                queries.append(.init(endpoint: "search", pair: .init(title: title, artist: artist), duration: nil))
            }
        }
        if let alias = CapturedBuild20LyricsCanonicalMetadata.alternateArtist(metadata.pair.artist) {
            queries.append(.init(endpoint: "search", pair: .init(title: metadata.pair.title, artist: alias), duration: nil))
        }
        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0.endpoint + "|" + $0.pair.title + "|" + $0.pair.artist + "|" + String($0.duration ?? 0)).inserted }.prefix(6))
    }

    static func secondaryPairs(_ metadata: CapturedBuild20LyricsCanonicalMetadata) -> [CapturedBuild20LyricsLookupMetadata.Pair] {
        var seen = Set<String>()
        let original = CapturedBuild20LyricsLookupMetadata.Pair(title: metadata.originalTitle, artist: metadata.originalArtist)
        return Array(([original, metadata.pair] + queries(metadata).map(\.pair))
            .filter { seen.insert($0.title + "|" + $0.artist).inserted && (!$0.artist.isEmpty || metadata.pair.artist.isEmpty) }.prefix(6))
    }
}

enum CapturedBuild20LyricsCandidateScorer {
    static func score(_ candidate: LyricsCandidate, metadata: CapturedBuild20LyricsCanonicalMetadata) -> Int? {
        let title = metadata.context.hasYouTubeOrigin ? CapturedBuild20LyricsCanonicalMetadata.presentationTitle(candidate.title) : candidate.title
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CapturedBuild20LyricsCanonicalMetadata.versions(title) == metadata.versionTags,
              CapturedBuild20LyricsLookupMetadata.identityKey(title) == CapturedBuild20LyricsLookupMetadata.identityKey(metadata.pair.title) else { return nil }
        var score = CapturedBuild20LyricsLookupMetadata.normalized(candidate.title) == CapturedBuild20LyricsLookupMetadata.normalized(metadata.originalTitle) ? 40 : 35
        let tokens = CapturedBuild20LyricsCanonicalMetadata.tokens(candidate.artist)
        if let primary = metadata.artistTokens.first {
            guard let otherPrimary = tokens.first,
                  CapturedBuild20LyricsCanonicalMetadata.artistIdentity(primary) == CapturedBuild20LyricsCanonicalMetadata.artistIdentity(otherPrimary) else { return nil }
            let expected = Set(metadata.artistTokens.map(CapturedBuild20LyricsCanonicalMetadata.artistIdentity))
            let actual = Set(tokens.map(CapturedBuild20LyricsCanonicalMetadata.artistIdentity))
            // A different credited guest changes recording identity; incomplete credits are manual.
            guard actual.isSubset(of: expected) || expected.isSubset(of: actual) else { return nil }
            if CapturedBuild20LyricsLookupMetadata.normalized(candidate.artist) == CapturedBuild20LyricsLookupMetadata.normalized(metadata.pair.artist) { score += 30 }
            else if Set(tokens) == Set(metadata.artistTokens) { score += 25 }
            else if expected == actual { score += 20 }
            else { return min(score + 40, 84) }
        }
        if let album = candidate.album, let expected = metadata.context.album,
           !expected.isEmpty, CapturedBuild20LyricsLookupMetadata.identityKey(album) == CapturedBuild20LyricsLookupMetadata.identityKey(expected) { score += 10 }
        if let duration = candidate.duration, duration.isFinite, duration > 0, let expected = metadata.context.duration {
            let delta = abs(duration - Double(expected))
            score += delta <= 2 ? 15 : delta <= 5 ? 10 : delta <= 10 ? 5 : 0
        }
        score += 20 // Exact version set, including an explicitly untagged studio recording.
        return score
    }

    static func remembered(_ context: CapturedBuild20LyricsLookupContext, defaults: UserDefaults) -> LyricsRecordID? {
        LyricsSelectionStore.selectedRecord(for: context.selectionKey, defaults: defaults)
            ?? LyricsSelectionStore.selectedRecord(for: context.legacySelectionKey, defaults: defaults)
    }

    static func choose(_ candidates: [LyricsCandidate], metadata: CapturedBuild20LyricsCanonicalMetadata,
                       defaults: UserDefaults, failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var accepted: [LyricsRecordID: (LyricsCandidate, Int)] = [:]
        for candidate in candidates {
            guard let score = score(candidate, metadata: metadata),
                  score >= 65 || metadata.artistTokens.isEmpty else { continue }
            // Rejected identities never reserve an ID. Keep the stronger complete record,
            // including newly verified timestamps, without merging different timelines.
            if let previous = accepted[candidate.id],
               previous.1 > score || (previous.1 == score && (previous.0.lyrics.isTimeSynced || !candidate.lyrics.isTimeSynced)) {
                continue
            }
            accepted[candidate.id] = (candidate, score)
        }
        let ranked = accepted.values.sorted { $0.1 == $1.1 ? $0.0.id.providerID.rawValue + $0.0.id.recordID < $1.0.id.providerID.rawValue + $1.0.id.recordID : $0.1 > $1.1 }
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

import Foundation

enum CapturedBuild20LyricsLookupMetadata {
    struct Pair {
        let title: String
        let artist: String
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Script and presentation punctuation may differ; the full version words remain.
    static func identityKey(_ value: String) -> String {
        let script = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return normalized(script).replacingOccurrences(of: "[\\p{P}\\p{Z}]+", with: "", options: .regularExpression)
    }

    static func performerKey(_ value: String) -> String {
        let script = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        // Preserve duet/collaboration separators so A/B can never become AB.
        return normalized(script).replacingOccurrences(of: "[\\s.。'’‘]+", with: "", options: .regularExpression)
    }

    /// Normalize collaboration separators without ever collapsing A/B into AB.
    static func matchingPerformerKey(_ value: String) -> String {
        performerKey(value).components(separatedBy: CharacterSet(charactersIn: "&+/×,、|;；"))
            .filter { !$0.isEmpty }.sorted().joined(separator: "|")
    }

    /// Secondary queries use the same explicit credit rules as primary retries.
    static func secondaryPair(title: String, artist: String, allowVideoCredits: Bool) -> Pair? {
        var pair = Pair(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist: artist.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !pair.title.isEmpty else { return nil }
        if pair.artist.isEmpty {
            guard allowVideoCredits else { return nil }
            if let credit = cleaned(title: pair.title, artist: pair.artist, allowVideoCredits: true) {
                pair = credit
            } else {
                guard !pair.title.contains(" - "), !pair.title.contains("《"), !pair.title.contains("【") else { return nil }
                return pair // Unknown performer remains a manual choice.
            }
        } else if let clean = cleaned(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) {
            pair = clean
        }
        return chineseVideoPair(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) ?? pair
    }

    static func simplifiedPair(_ pair: Pair) -> Pair? {
        let title = pair.title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? pair.title
        let artist = pair.artist.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? pair.artist
        guard title != pair.title || artist != pair.artist else { return nil }
        return Pair(title: title, artist: artist)
    }

    static func cleaned(title: String, artist: String, allowVideoCredits: Bool) -> Pair? {
        var lookupInput = title
        if allowVideoCredits {
            lookupInput = lookupInput.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression)
            lookupInput = strippingChineseLyricPresentation(lookupInput)
            lookupInput = strippingPresentationSuffix(lookupInput)
            let songBrackets: [(Character, Character)] = [("《", "》"), ("【", "】")]
            for (opening, closing) in songBrackets {
                guard lookupInput.filter({ $0 == opening }).count == 1,
                      lookupInput.filter({ $0 == closing }).count == 1,
                      let open = lookupInput.firstIndex(of: opening),
                      let close = lookupInput.firstIndex(of: closing), open < close,
                      !lookupInput[..<open].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !lookupInput[..<open].contains(" - ")
                else { continue }
                let credit = String(lookupInput[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s*[-–—－]\\s*$", with: "", options: .regularExpression)
                let track = String(lookupInput[lookupInput.index(after: open)..<close])
                let suffix = String(lookupInput[lookupInput.index(after: close)...])
                lookupInput = credit + " - " + track + (suffix.isEmpty ? "" : " " + suffix)
                break
            }
        }
        let parts = lookupInput.components(separatedBy: " - ")
        guard parts.count <= 2, allowVideoCredits || parts.count == 2 else { return nil }
        var lookupTitle = lookupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var lookupArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if parts.count == 2 {
            let credit = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !credit.isEmpty, !hasGuestCredit(credit), !hasGuestCredit(lookupArtist) else { return nil }
            if normalized(credit) == normalized(lookupArtist) || allowVideoCredits {
                lookupTitle = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                lookupArtist = credit
            } else { return nil }
        }
        lookupTitle = strippingPresentationSuffix(lookupTitle)
        if allowVideoCredits { lookupTitle = strippingChineseLyricPresentation(lookupTitle) }
        guard !lookupTitle.isEmpty, !lookupArtist.isEmpty,
              normalized(lookupTitle) != normalized(title) || normalized(lookupArtist) != normalized(artist) else { return nil }
        return Pair(title: lookupTitle, artist: lookupArtist)
    }

    /// A verified video can credit one performer with Chinese and Latin names.
    /// Keep the original metadata, but try the explicit Han name after exact lookup fails.
    static func chineseVideoPair(title: String, artist: String, allowVideoCredits: Bool) -> Pair? {
        guard allowVideoCredits else { return nil }
        let pair = cleaned(title: title, artist: artist, allowVideoCredits: true)
            ?? Pair(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: artist.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !hasGuestCredit(pair.artist) else { return nil }
        var lookupTitle = pair.title
        var lookupArtist = pair.artist
        if let hanName = capture("^([\\p{Han}]{2,})\\s*[A-Za-z][A-Za-z .'-]*$", in: lookupArtist) {
            lookupArtist = hanName
        }
        if let hanTitle = capture("^([\\p{Han}]+)\\s+[A-Za-z][A-Za-z\\s'’,.?!-]*$", in: lookupTitle) {
            let version = "(?i)\\b(live|remix|cover|acoustic|instrumental|karaoke|version|edit|mix|sped|slowed|remaster(?:ed)?|demo|original|extended)\\b"
            guard lookupTitle.range(of: version, options: .regularExpression) == nil else { return nil }
            lookupTitle = hanTitle
        }
        guard !lookupTitle.isEmpty, !lookupArtist.isEmpty,
              normalized(lookupTitle) != normalized(pair.title)
                || normalized(lookupArtist) != normalized(pair.artist) else { return nil }
        return Pair(title: lookupTitle, artist: lookupArtist)
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func strippingChineseLyricPresentation(_ input: String) -> String {
        // Only explicit lyric/video labels authorize removal of a quoted lyric snippet.
        // A performance/version label never authorizes removal.
        let versions = "(?i)(live|remix|cover|acoustic|instrumental|karaoke|翻唱|现场|現場|演唱会|演唱會|改编|改編|加速|慢速)"
        guard input.range(of: versions, options: .regularExpression) == nil else { return input }
        let label = "(?i)(?:[【『（(\\[][^】』）)\\]]*(?:動態歌詞|动态歌词|非官方歌詞|非官方歌词|lyrics?\\s*(?:video)?)[^】』）)\\]]*[】』）)\\]]|官方動態歌詞版|官方动态歌词版)[\\s♫♪]*$"
        var value = input
        var removedLabel = false
        while let range = value.range(of: label, options: .regularExpression) {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            removedLabel = true
        }
        if removedLabel {
            let quoted = "\\s*[♫♪]?\\s*(?:『[^』]*』|「[^」]*」|◖[^◗]*◗)\\s*$"
            while let range = value.range(of: quoted, options: .regularExpression) {
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.isEmpty ? input : value
    }

    private static func strippingPresentationSuffix(_ input: String) -> String {
        var value = input
        let bare = "(?:official\\s+(?:music\\s+video|video|audio|mv|lyric\\s+video|lyrics\\s+video)|music\\s+video|lyric\\s+video|lyrics\\s+video|官方\\s*(?:mv|音樂錄影帶|音乐录影带|歌詞影片|歌词影片))"
        let bracketed = "(?:\(bare)|官方頻道|官方频道)"
        let suffix = "(?i)(?:\\s*\\(\\s*\(bracketed)\\s*\\)|\\s*\\[\\s*\(bracketed)\\s*\\]|\\s*【\\s*\(bracketed)\\s*】|\\s+\(bare))\\s*$"
        while let range = value.range(of: suffix, options: .regularExpression) {
            let preceding = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized(preceding).hasSuffix("unofficial") else { break }
            value = preceding
        }
        return value
    }

    private static func hasGuestCredit(_ value: String) -> Bool {
        let text = normalized(value)
        return text.contains(where: { "&+×/,、|".contains($0) })
            || text.range(of: "\\b(feat|featuring|ft|with|vs|versus)\\b", options: .regularExpression) != nil
    }
}

import Foundation

final class CapturedBuild20LrcLibService: CapturedBuild20LyricsRepositoryProtocol {
    private let baseURL = URL(string: "https://lrclib.net/api")!
    private let session: URLSession
    private let defaults: UserDefaults
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
        self.session = session ?? CapturedBuild20LyricsTransportPolicy.makeSession()
        self.defaults = defaults
    }

    func getLyrics(context: CapturedBuild20LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let metadata = CapturedBuild20LyricsCanonicalMetadata(context) else { return nil }
        var candidates: [LyricsCandidate] = []
        var failures: [LyricsSourceFailure] = []
        // The official GET /api/get/:track_id endpoint revalidates identity and content.
        if let saved = CapturedBuild20LyricsCandidateScorer.remembered(context, defaults: defaults), saved.providerID == .lrclib,
           let id = Int(saved.recordID), id > 0 {
            do {
                let response = try await request(endpoint: "get/" + String(id), items: [])
                if response.status == 200 {
                    let record = try decoder.decode(LrcLibResponse.self, from: response.data)
                    if let candidate = contextCandidate(record, context: context), candidate.id == saved,
                       CapturedBuild20LyricsCandidateScorer.score(candidate, metadata: metadata) != nil {
                        return CapturedBuild20LyricsCandidateScorer.choose([candidate], metadata: metadata, defaults: defaults)
                    }
                } else if response.status != 404 { throw PublicSourceError.http("LRCLib", response.status) }
            } catch {
                try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
            }
        }
        for query in CapturedBuild20LyricsQueryPlanner.queries(metadata) {
            try Task.checkCancellation()
            do {
                let records: [LrcLibResponse]
                if query.endpoint == "get" {
                    let response = try await get(pair: query.pair, duration: query.duration)
                    if response.status == 404 { continue }
                    guard response.status == 200 else { throw PublicSourceError.http("LRCLib", response.status) }
                    records = [try decoder.decode(LrcLibResponse.self, from: response.data)]
                } else {
                    records = try await search(pair: query.pair)
                }
                // Invalid identities are rejected by the common scorer, never before search fallback.
                candidates += records.prefix(30).compactMap { contextCandidate($0, context: context) }
                if let result = CapturedBuild20LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) {
                    if query.endpoint == "search" || (!result.lines.isEmpty && result.isTimeSynced) { return result }
                }
            } catch {
                try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
                break // Availability errors are not corrected by spelling variants.
            }
        }
        try Task.checkCancellation()
        if let result = CapturedBuild20LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) { return result }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }

    private func contextCandidate(_ record: LrcLibResponse, context: CapturedBuild20LyricsLookupContext) -> LyricsCandidate? {
        guard let id = record.id, id > 0, let title = record.trackName, let artist = record.artistName,
              let lyrics = lyrics(record, duration: context.duration) else { return nil }
        return LyricsCandidate(id: .init(providerID: .lrclib, recordID: String(id)),
                               title: title, artist: artist, duration: record.duration, lyrics: lyrics, album: record.albumName)
    }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var pair = CapturedBuild20LyricsLookupMetadata.Pair(title: title, artist: artist)
        var hasExplicitPair = false
        if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard allowVideoCredits else { return nil }
            if let credit = CapturedBuild20LyricsLookupMetadata.cleaned(title: title, artist: artist, allowVideoCredits: true) {
                pair = credit
                hasExplicitPair = true
            } else {
                // Missing performer is a manual-choice flow, never an automatic match.
                // Ambiguous embedded credits must not be guessed into a bare song title.
                guard !title.contains(" - "), !title.contains("《"), !title.contains("【") else { return nil }
                let validDuration = CapturedBuild20LyricsMatchingPolicy.validDuration(duration)
                var matches = try await search(pair: pair)
                if matches.isEmpty, let simplified = CapturedBuild20LyricsLookupMetadata.simplifiedPair(pair) {
                    pair = simplified
                    matches = try await search(pair: pair)
                }
                let key = CapturedBuild20LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
                return choose(matches, pair: pair, duration: validDuration, key: key, missingArtist: true)
            }
        }
        let validDuration = CapturedBuild20LyricsMatchingPolicy.validDuration(duration)
        var response = try await get(pair: pair, duration: validDuration)
        if response.status == 404, validDuration != nil {
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404,
           let clean = CapturedBuild20LyricsLookupMetadata.cleaned(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) {
            pair = clean
            hasExplicitPair = true
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404,
           let chinese = CapturedBuild20LyricsLookupMetadata.chineseVideoPair(title: pair.title, artist: pair.artist, allowVideoCredits: allowVideoCredits) {
            pair = chinese
            hasExplicitPair = true
            response = try await get(pair: pair, duration: nil)
        }
        if response.status == 404, allowVideoCredits,
           let simplified = CapturedBuild20LyricsLookupMetadata.simplifiedPair(pair) {
            pair = simplified
            response = try await get(pair: pair, duration: nil)
        }
        let key = CapturedBuild20LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        if response.status == 404 {
            guard hasExplicitPair else { return nil }
            let matches = try await search(pair: pair)
            return choose(matches, pair: pair, duration: validDuration, key: key)
        }
        guard response.status == 200 else { throw PublicSourceError.http("LRCLib", response.status) }
        let match = try decoder.decode(LrcLibResponse.self, from: response.data)
        guard identityMatches(match, pair: pair), let lyrics = lyrics(match, duration: validDuration) else { return nil }
        // A trusted identity with uncertain timing can still provide useful text.
        // Search the same explicit pair to expose multiple recordings to the user.
        if !lyrics.isTimeSynced || LyricsSelectionStore.selectedRecord(for: key, defaults: defaults) != nil, match.id != nil {
            var matches: [LrcLibResponse]
            var failures: [LyricsSourceFailure] = []
            do { matches = try await search(pair: pair) }
            catch {
                try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
                matches = [match]
                failures.append(LyricsSourceFailure(providerID: .lrclib, message: error.localizedDescription))
            }
            try Task.checkCancellation()
            return choose([match] + matches, pair: pair, duration: validDuration, key: key, failures: failures)
        }
        try Task.checkCancellation()
        if match.id != nil {
            return choose([match], pair: pair, duration: validDuration, key: key)
        }
        return lyrics
    }

    private func get(pair: CapturedBuild20LyricsLookupMetadata.Pair, duration: Int?) async throws -> (data: Data, status: Int) {
        var items = [URLQueryItem(name: "track_name", value: pair.title), URLQueryItem(name: "artist_name", value: pair.artist)]
        if let duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        return try await request(endpoint: "get", items: items)
    }

    private func search(pair: CapturedBuild20LyricsLookupMetadata.Pair) async throws -> [LrcLibResponse] {
        var items = [URLQueryItem(name: "track_name", value: pair.title)]
        if !pair.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: pair.artist)) }
        let result = try await request(endpoint: "search", items: items)
        if result.status == 404 { return [] }
        guard result.status == 200 else { throw PublicSourceError.http("LRCLib", result.status) }
        return try decoder.decode([LrcLibResponse].self, from: result.data)
    }

    private func request(endpoint: String, items: [URLQueryItem]) async throws -> (data: Data, status: Int) {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            return (Data(), 404)
        }
        components.queryItems = items
        guard let url = components.url else { return (Data(), 404) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib")
        try Task.checkCancellation()
        return (data, response.statusCode)
    }

    private func identityMatches(_ match: LrcLibResponse, pair: CapturedBuild20LyricsLookupMetadata.Pair, missingArtist: Bool = false) -> Bool {
        CapturedBuild20LyricsMatchingPolicy.identityMatches(title: match.trackName, artist: match.artistName,
                                             pair: pair, missingArtist: missingArtist)
    }

    private func choose(_ matches: [LrcLibResponse], pair: CapturedBuild20LyricsLookupMetadata.Pair,
                        duration: Int?, key: String, missingArtist: Bool = false,
                        failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var seen: Set<Int> = []
        let candidates = matches.prefix(31).compactMap { match -> LyricsCandidate? in
            guard identityMatches(match, pair: pair, missingArtist: missingArtist), let id = match.id, seen.insert(id).inserted,
                  let lyrics = lyrics(match, duration: duration) else { return nil }
            return LyricsCandidate(id: LyricsRecordID(providerID: .lrclib, recordID: String(id)),
                                   title: match.trackName!, artist: match.artistName!, duration: match.duration, lyrics: lyrics)
        }
        return CapturedBuild20LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: missingArtist,
                                           defaults: defaults, failures: failures)
    }

    private func lyrics(_ match: LrcLibResponse, duration: Int?) -> SyncedLyrics? {
        CapturedBuild20LyricsMatchingPolicy.lyrics(syncedLRC: match.syncedLyrics ?? "", plainText: match.plainLyrics,
                                   recordingDuration: match.duration, videoDuration: duration, provider: .lrclib)
    }
}

private struct LrcLibResponse: Codable {
    let id: Int?
    let trackName: String?
    let albumName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}

import Foundation

enum CapturedBuild20LyricsSecondarySettings {
    static let enabledKey = "lyrics.secondary.lrcapi.enabled"
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Official public /jsonapi endpoint. No cookies, credentials, disk cache or batch lookup.
final class CapturedBuild20LrcApiService: CapturedBuild20LyricsRepositoryProtocol {
    private let session: URLSession
    private let defaults: UserDefaults
    private let timeout: TimeInterval
    private let retryTransient: Bool
    private let endpoint = URL(string: "https://api.lrc.cx/jsonapi")!

    init(session: URLSession? = nil, defaults: UserDefaults = .standard,
         timeout: TimeInterval = 8, retryTransient: Bool = true) {
        self.session = session ?? CapturedBuild20LyricsTransportPolicy.makeSession()
        self.defaults = defaults
        self.timeout = timeout.isFinite ? min(max(timeout, 0.1), 15) : 8
        self.retryTransient = retryTransient
    }

    func getLyrics(context: CapturedBuild20LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let metadata = CapturedBuild20LyricsCanonicalMetadata(context) else { return nil }
        var candidates: [LyricsCandidate] = []
        var failures: [LyricsSourceFailure] = []
        // jsonapi has no verified record-ID route. Revalidate saved IDs in bounded metadata responses.
        for pair in CapturedBuild20LyricsQueryPlanner.secondaryPairs(metadata) {
            try Task.checkCancellation()
            do {
                let records = try await request(pair: pair)
                try Task.checkCancellation()
                candidates += records.prefix(30).compactMap { record -> LyricsCandidate? in
                    guard !record.id.isEmpty, record.id.count <= 256, let title = record.title, let artist = record.artist,
                          let lyrics = CapturedBuild20LyricsMatchingPolicy.lyrics(syncedLRC: record.lrc ?? record.lyrics ?? "",
                              plainText: record.lyrics, recordingDuration: record.duration,
                              videoDuration: context.duration, provider: .lrcapi) else { return nil }
                    return LyricsCandidate(id: .init(providerID: .lrcapi, recordID: record.id),
                                           title: title, artist: artist, duration: record.duration, lyrics: lyrics, album: record.album)
                }
                if let result = CapturedBuild20LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures) {
                    return result
                }
            } catch {
                try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
                failures.append(.init(providerID: .lrcapi, message: error.localizedDescription))
                break
            }
        }
        if !failures.isEmpty { throw LyricsLookupError.unavailable(failures) }
        return nil
    }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let pair = CapturedBuild20LyricsLookupMetadata.secondaryPair(title: title, artist: artist,
                                                           allowVideoCredits: allowVideoCredits) else { return nil }
        let missingArtist = pair.artist.isEmpty
        let key = CapturedBuild20LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        var pairs = [pair]
        if let simplified = CapturedBuild20LyricsLookupMetadata.simplifiedPair(pair) { pairs.append(simplified) }
        // At most two spelling queries, each with at most one transient retry.
        for lookup in pairs.prefix(2) {
            try Task.checkCancellation()
            let records = try await request(pair: lookup)
            try Task.checkCancellation()
            var seen = Set<String>()
            let candidates = records.prefix(30).compactMap { record -> LyricsCandidate? in
                guard !record.id.isEmpty, seen.insert(record.id).inserted,
                      CapturedBuild20LyricsMatchingPolicy.identityMatches(title: record.title, artist: record.artist,
                                                           pair: lookup, missingArtist: missingArtist),
                      let lyrics = CapturedBuild20LyricsMatchingPolicy.lyrics(syncedLRC: record.lrc ?? record.lyrics ?? "",
                          plainText: record.lyrics, recordingDuration: record.duration,
                          videoDuration: duration, provider: .lrcapi) else { return nil }
                return LyricsCandidate(id: LyricsRecordID(providerID: .lrcapi, recordID: record.id),
                                       title: record.title!, artist: record.artist!, duration: record.duration, lyrics: lyrics)
            }
            if let result = CapturedBuild20LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: missingArtist,
                                                       defaults: defaults) { return result }
        }
        return nil
    }

    private func request(pair: CapturedBuild20LyricsLookupMetadata.Pair) async throws -> [LrcApiRecord] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "title", value: pair.title)]
        if !pair.artist.isEmpty { query.append(URLQueryItem(name: "artist", value: pair.artist)) }
        components.queryItems = query
        guard let url = components.url else { throw PublicSourceError.invalidResponse("LrcApi") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session,
                                                                source: "LrcApi", retryTransient: retryTransient)
        try Task.checkCancellation()
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 200 else { throw PublicSourceError.http("LrcApi", response.statusCode) }
        guard data.count <= 2 * 1024 * 1024 else { throw PublicSourceError.invalidResponse("LrcApi") }
        return try JSONDecoder().decode([LrcApiRecord].self, from: data)
    }
}

private struct LrcApiRecord: Decodable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let duration: Double?
    let lyrics: String?
    let lrc: String?

    enum CodingKeys: String, CodingKey { case id, title, artist, album, duration, lyrics, lrc }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? c.decode(String.self, forKey: .id) { id = string }
        else if let number = try? c.decode(Int.self, forKey: .id) { id = String(number) }
        else { id = "" }
        title = try c.decodeIfPresent(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        lrc = try c.decodeIfPresent(String.self, forKey: .lrc)
    }
}

/// Shared by both lyric adapters; lyric content is not written to URLCache or cookies.
enum CapturedBuild20LyricsTransportPolicy {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }
}

import Foundation

/// Primary-first lookup; independent candidate recordings never share a timeline.
final class CapturedBuild20CompositeLyricsRepository: CapturedBuild20LyricsRepositoryProtocol {
    private let primary: CapturedBuild20LyricsRepositoryProtocol
    private let secondary: CapturedBuild20LyricsRepositoryProtocol
    private let defaults: UserDefaults
    private let secondaryEnabled: () -> Bool

    init(primary: CapturedBuild20LyricsRepositoryProtocol, secondary: CapturedBuild20LyricsRepositoryProtocol,
         defaults: UserDefaults = .standard, secondaryEnabled: (() -> Bool)? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.defaults = defaults
        self.secondaryEnabled = secondaryEnabled ?? { CapturedBuild20LyricsSecondarySettings.isEnabled(defaults: defaults) }
    }

    func getLyrics(context: CapturedBuild20LyricsLookupContext) async throws -> SyncedLyrics? {
        try Task.checkCancellation()
        guard let metadata = CapturedBuild20LyricsCanonicalMetadata(context) else { return nil }
        let saved = CapturedBuild20LyricsCandidateScorer.remembered(context, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var first: SyncedLyrics?
        do {
            first = try await primary.getLyrics(context: context)
            try Task.checkCancellation()
            failures += first?.sourceFailures ?? []
        } catch {
            try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
            failures.append(.init(providerID: .lrclib, message: error.localizedDescription))
        }
        let enabled = secondaryEnabled()
        if let first, !first.lines.isEmpty, first.isTimeSynced,
           !enabled || saved?.providerID != .lrcapi { return first }
        guard enabled else {
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
            try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
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
            return CapturedBuild20LyricsCandidateScorer.choose(candidates, metadata: metadata, defaults: defaults, failures: failures)
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
        let key = CapturedBuild20LyricsMatchingPolicy.selectionKey(title: title, artist: artist, duration: duration)
        let remembered = LyricsSelectionStore.selectedRecord(for: key, defaults: defaults)
        var failures: [LyricsSourceFailure] = []
        var first: SyncedLyrics?
        do {
            first = try await primary.getLyrics(title: title, artist: artist, duration: duration,
                                                allowVideoCredits: allowVideoCredits)
            try Task.checkCancellation()
            failures += first?.sourceFailures ?? []
        } catch {
            try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
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
            try CapturedBuild20LyricsMatchingPolicy.checkCancellation(error)
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
            let pair = CapturedBuild20LyricsLookupMetadata.secondaryPair(title: title, artist: artist,
                                                         allowVideoCredits: allowVideoCredits)
            return CapturedBuild20LyricsMatchingPolicy.choose(candidates, key: key, missingArtist: pair?.artist.isEmpty ?? true,
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

import Foundation

/// Both providers share identity, version, duration and timestamp acceptance.
enum CapturedBuild20LyricsMatchingPolicy {
    static func validDuration(_ duration: Int?) -> Int? {
        duration.flatMap { (1...3600).contains($0) ? $0 : nil }
    }

    static func selectionKey(title: String, artist: String, duration: Int?) -> String {
        // Keep the existing key so old LRCLib selections remain addressable.
        CapturedBuild20LyricsLookupMetadata.identityKey(title) + "|" + CapturedBuild20LyricsLookupMetadata.performerKey(artist)
            + "|" + String(validDuration(duration) ?? 0)
    }

    static func identityMatches(title: String?, artist: String?, pair: CapturedBuild20LyricsLookupMetadata.Pair,
                                missingArtist: Bool = false) -> Bool {
        guard let title, let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return CapturedBuild20LyricsLookupMetadata.identityKey(title) == CapturedBuild20LyricsLookupMetadata.identityKey(pair.title)
            && (missingArtist || CapturedBuild20LyricsLookupMetadata.matchingPerformerKey(artist)
                == CapturedBuild20LyricsLookupMetadata.matchingPerformerKey(pair.artist))
    }

    static func checkCancellation(_ error: Error? = nil) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
    }

    static func lyrics(syncedLRC: String, plainText: String?, recordingDuration: Double?,
                       videoDuration: Int?, provider: LyricsProviderID) -> SyncedLyrics? {
        let timed = parseLRC(syncedLRC)
        let video = validDuration(videoDuration)
        let compatible = video.flatMap { video in
            recordingDuration.map { $0.isFinite && $0 > 0 && abs($0 - Double(video)) <= 1 }
        } ?? false
        if compatible, let video, !timed.isEmpty,
           timed.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= Double(video) + 1 }) {
            return SyncedLyrics(lines: timed, source: provider.displayName, providerID: provider)
        }
        let plain = plainLines(plainText ?? "")
        let fallback = plain.isEmpty ? plainLines(syncedLRC) : plain
        guard !fallback.isEmpty else { return nil }
        return SyncedLyrics(lines: fallback.map { LyricLine(time: 0, text: $0) },
                            source: provider.displayName + " (plain)", isTimeSynced: false, providerID: provider)
    }

    static func choose(_ candidates: [LyricsCandidate], key: String, missingArtist: Bool,
                       defaults: UserDefaults, failures: [LyricsSourceFailure] = []) -> SyncedLyrics? {
        var seen = Set<LyricsRecordID>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }
        let remembered = LyricsSelectionStore.selectedRecord(for: key, defaults: defaults)
            .flatMap { id in unique.first { $0.id == id } }
        let chosen = remembered ?? (!missingArtist && unique.count == 1 ? unique[0] : nil)
        return SyncedLyrics(lines: chosen?.lyrics.lines ?? [], source: chosen?.lyrics.source ?? "",
                            isTimeSynced: chosen?.lyrics.isTimeSynced ?? false,
                            candidates: unique, selectionKey: key, providerID: chosen?.providerID,
                            sourceFailures: failures)
    }

    static func parseLRC(_ input: String) -> [LyricLine] {
        guard let pattern = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2}(?:[.:]\\d+)?)\\]") else { return [] }
        var output: [LyricLine] = []
        for line in input.components(separatedBy: .newlines) {
            guard line.hasPrefix("[") else { continue }
            let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last, let tail = Range(last.range, in: line) else { continue }
            // Timestamp matches must form a contiguous prefix, never tags embedded in lyric text.
            var end = 0
            guard matches.allSatisfy({ match in
                guard match.range.location == end else { return false }
                end = NSMaxRange(match.range)
                return true
            }) else { continue }
            let text = String(line[tail.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let m = Range(match.range(at: 1), in: line), let s = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[m]),
                      let seconds = Double(line[s].replacingOccurrences(of: ":", with: ".")),
                      minutes.isFinite, seconds.isFinite, (0..<60).contains(seconds) else { continue }
                output.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return output.sorted { $0.time < $1.time }
    }

    private static func plainLines(_ input: String) -> [String] {
        input.components(separatedBy: .newlines).compactMap { original in
            var text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[!text]") { text.removeFirst(7) }
            text = text.replacingOccurrences(of: "^(?:\\[\\d{1,3}:\\d{2}(?:[.:]\\d+)?\\])+", with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.range(of: "^\\[(?:ar|ti|al|by|offset|length|re|ve):", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return text
        }
    }
}

import Foundation

protocol CapturedBuild20LyricsRepositoryProtocol {
    func getLyrics(context: CapturedBuild20LyricsLookupContext) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics?
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics?
}

extension CapturedBuild20LyricsRepositoryProtocol {
    func getLyrics(context: CapturedBuild20LyricsLookupContext) async throws -> SyncedLyrics? {
        try await getLyrics(title: context.title, artist: context.artist, duration: context.duration,
                            allowVideoCredits: context.hasYouTubeOrigin)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration)
    }
}

