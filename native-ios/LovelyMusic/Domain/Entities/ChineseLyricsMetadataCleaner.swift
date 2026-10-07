import Foundation

/// Lookup-only interpretations. None of these values are written into Song or an import manifest.
enum ChineseLyricsMetadataCleaner {
    struct Analysis {
        let pair: LyricsLookupMetadata.Pair
        let presentationContext: [String]
    }

    private static func replacing(_ pattern: String, in text: String, with value: String = "") -> String {
        text.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preparedTitle(_ original: String, suppliedArtist: String = "") -> String {
        var value = LyricsLookupMetadata.boundedQueryPresentation(original).trimmingCharacters(in: .whitespacesAndNewlines)
        let promo = "(?:新歌|首播|完整版|完整發行版|完整发行版|MV|Official MV)"
        // A channel prefix needs an adjacent recognized promotion label. Unknown bracket titles survive.
        value = replacing("(?i)^\\[[A-Za-z][A-Za-z0-9 ._-]{1,40}\\]\\s*(?=\\[" + promo + "\\])", in: value)
        for _ in 0..<6 {
            let next = replacing("(?i)^(?:\\[" + promo + "\\]|【" + promo + "】)\\s*", in: value)
            if next == value { break }; value = next
        }
        value = replacing(" [–—－─━] ", in: value, with: " - ")
        // Compact Han credits remain two uncertain role hypotheses; this is not a performer assertion.
        value = replacing("^([\\p{Han}]{2,4})\\s*[-–—－]\\s*(?=\\S)", in: value, with: "$1 - ")
        if !suppliedArtist.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: suppliedArtist)
            value = replacing("^" + escaped + "\\s*[-–—－]\\s*(?=\\S)", in: value, with: suppliedArtist + " - ")
        }
        return strippingLyricLabels(value)
    }

    private static func strippingLyricLabels(_ original: String) -> String {
        let words = "(?:(?:高音質|高音质)\\s*)?(?:歌詞版|歌词版|有歌詞字幕\\s*Lyrics|有歌词字幕\\s*Lyrics|官方歌詞版|官方歌词版|完整版|完整發行版|完整发行版|(?:動態歌詞|动态歌词|lyrics?(?:\\s*video)?)(?:\\s*/\\s*(?:Vietsub|Pinyin\\s*Lyrics?|PinyinLyrics))*|Visualizer|4K|HD)"
        let pattern = "(?i)\\s*(?:\\(" + words + "\\)|（" + words + "）|\\[" + words + "\\]|【" + words + "】)\\s*[♪♫]?\\s*$"
        // Preserve the lyric label as evidence before stripping a quoted snippet.
        var value = LyricsLookupMetadata.strippingChineseLyricPresentation(original)
        for _ in 0..<6 {
            let next = replacing(pattern, in: value)
            if next == value || next.isEmpty { break }; value = next
        }
        let boundedOST = "\\s*[（(](?:台劇|台剧|電視劇|电视剧|電影|电影)([\\p{Han}]{1,40})(?:片尾曲|片頭曲|片头曲|主題曲|主题曲|插曲)[）)]\\s*$"
        if let range = value.range(of: boundedOST, options: .regularExpression),
           LyricsCanonicalMetadata.versions(String(value[range])).isEmpty {
            let withoutOST = replacing(boundedOST, in: value)
            if !withoutOST.isEmpty { value = withoutOST }
        }
        // Existing bounded lyric-snippet and named-work rules protect formal quoted titles and versions.
        return LyricsLookupMetadata.strippingVideoPresentation(
            LyricsLookupMetadata.strippingChineseLyricPresentation(value))
    }

    private static func feature(_ text: String) -> (title: String, guest: String)? {
        let patterns = [
            "(?i)^(.+?)\\s+\\b(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()（）【】《》〈〉『』「」]{1,100})$",
            "(?i)^(.+?)\\s*\\(\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()（）【】《》〈〉『』「」]{1,100})\\)$",
            "(?i)^(.+?)\\s*\\[\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()（）【】《》〈〉『』「」]{1,100})\\]$",
            "(?i)^(.+?)\\s*（\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()（）【】《》〈〉『』「」]{1,100})）$",
            "(?i)^(.+?)\\s*【\\s*(?:feat(?:uring)?|ft)(?:\\.\\s*|\\s+)([^\\[\\]()（）【】《》〈〉『』「」]{1,100})】$"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let title = Range(match.range(at: 1), in: text), let guest = Range(match.range(at: 2), in: text) else { continue }
            let credit = String(text[guest]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(text[title]).trimmingCharacters(in: .whitespacesAndNewlines)
            // The bare-credit pattern must not consume an unclosed bracket as part of the title.
            guard !credit.isEmpty, LyricsCanonicalMetadata.versions(credit).isEmpty,
                  !["(", "[", "（", "【"].contains(where: { body.hasSuffix($0) }) else { continue }
            return (strippingLyricLabels(body), credit)
        }
        return nil
    }

    private static func adding(_ guest: String?, to pair: LyricsLookupMetadata.Pair) -> LyricsLookupMetadata.Pair {
        guard let guest, !pair.artist.isEmpty else { return pair }
        let existing = Set(LyricsCanonicalMetadata.tokens(pair.artist))
        let guests = Set(LyricsCanonicalMetadata.tokens(guest))
        return .init(title: pair.title, artist: guests.isSubset(of: existing) ? pair.artist : pair.artist + " feat. " + guest)
    }

    static func roles(_ context: LyricsLookupContext) -> [LyricsLookupMetadata.Pair] {
        guard context.hasYouTubeOrigin else { return [] }
        let supplied = context.artistNameSource == .uploader ? "" : context.artist
        let prepared = preparedTitle(context.title, suppliedArtist: supplied)
        let credit = feature(prepared)
        let title = credit?.title ?? prepared
        let input = LyricsLookupContext(title: title, artist: supplied, hasYouTubeOrigin: true)
        let preparedRoles = LyricsLookupMetadata.videoCreditPairsLegacy(input)
        // Retain the observed official/publisher suffix before preparedTitle removes it.
        // Bare whitespace titles still fail this guard and never become credits.
        let originalRoles = preparedRoles.isEmpty && LyricsLookupMetadata.isWhitespaceVideoCredit(context.title)
            ? LyricsLookupMetadata.videoCreditPairsLegacy(.init(title: context.title, artist: supplied, hasYouTubeOrigin: true)) : []
        return (preparedRoles.isEmpty ? originalRoles : preparedRoles).map { adding(credit?.guest, to: $0) }
    }

    static func analyze(_ context: LyricsLookupContext) -> Analysis {
        let supplied = context.artistNameSource == .uploader ? "" : context.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.hasYouTubeOrigin else {
            return .init(pair: LyricsLookupMetadata.cleanedLegacy(title: context.title, artist: supplied, allowVideoCredits: false)
                ?? .init(title: context.title, artist: supplied), presentationContext: [])
        }
        let prepared = preparedTitle(context.title, suppliedArtist: supplied)
        let credit = feature(prepared)
        let title = credit?.title ?? prepared
        let whitespaceAlternative = supplied.isEmpty && LyricsLookupMetadata.isWhitespaceVideoCredit(context.title)
            ? roles(context).first : nil
        let pair = LyricsLookupMetadata.cleanedLegacy(title: title, artist: supplied, allowVideoCredits: true)
            ?? whitespaceAlternative ?? .init(title: title, artist: supplied)
        let result = adding(credit?.guest, to: .init(title: strippingLyricLabels(pair.title), artist: pair.artist))
        // Named works are weak context only; never a required title or performer identity.
        let pattern = "《([^《》]{1,80})》[^《》]{0,40}(?:插曲|主題曲|主题曲|片尾曲|片頭曲|片头曲)"
        var contextValues: [String] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: context.title, range: NSRange(context.title.startIndex..., in: context.title)) {
                if let range = Range(match.range(at: 1), in: context.title) { contextValues.append(String(context.title[range])) }
            }
        }
        let parentheticalWork = "[（(](?:台劇|台剧|電視劇|电视剧|電影|电影)([\\p{Han}]{1,40})(?:片尾曲|片頭曲|片头曲|主題曲|主题曲|插曲)[）)]"
        if let regex = try? NSRegularExpression(pattern: parentheticalWork) {
            for match in regex.matches(in: context.title, range: NSRange(context.title.startIndex..., in: context.title)) {
                if let range = Range(match.range(at: 1), in: context.title) { contextValues.append(String(context.title[range])) }
            }
        }
        return .init(pair: result, presentationContext: Array(Set(contextValues)).sorted())
    }

    /// Query and scorer consume these exact, bounded variants from the same role interpretation.
    static func titleVariants(_ title: String, context: LyricsLookupContext) -> [String] {
        var values = [title]
        guard context.hasYouTubeOrigin, LyricsCanonicalMetadata.versions(title).isEmpty else { return values }
        let prepared = preparedTitle(context.title, suppliedArtist: context.artist)
        let explicit = LyricsLookupMetadata.bracketedVideoCredit(prepared) != nil || prepared.contains(" - ")
        let pattern = "^([\\p{Han}]+)\\s+([A-Za-z][A-Za-z\\s'’,.?!-]*)$"
        if explicit, let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let han = Range(match.range(at: 1), in: title), let latin = Range(match.range(at: 2), in: title) {
            values += [String(title[han]), String(title[latin])]
        }
        return values
    }

    static func primaryHanCredit(_ credit: String) -> String? {
        let pattern = "^([\\p{Han}]{2,})\\s+[A-Za-z][A-Za-z .'-]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: credit, range: NSRange(credit.startIndex..., in: credit)),
              let range = Range(match.range(at: 1), in: credit) else { return nil }
        return String(credit[range])
    }
}
