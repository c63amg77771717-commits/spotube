import Foundation

enum LyricsLookupMetadata {
    struct Pair {
        let title: String
        let artist: String
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func cleaned(title: String, artist: String, allowVideoCredits: Bool) -> Pair? {
        var lookupInput = title
        if allowVideoCredits {
            lookupInput = lookupInput.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression)
            if lookupInput.filter({ $0 == "《" }).count == 1,
               lookupInput.filter({ $0 == "》" }).count == 1,
               let open = lookupInput.firstIndex(of: "《"), let close = lookupInput.firstIndex(of: "》"),
               open < close, !lookupInput[..<open].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !lookupInput[lookupInput.index(after: close)...].contains("《") {
                let credit = String(lookupInput[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
                let track = String(lookupInput[lookupInput.index(after: open)..<close])
                let suffix = String(lookupInput[lookupInput.index(after: close)...])
                lookupInput = credit + " - " + track + suffix
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
        let bare = "(?:official\\s+(?:music\\s+video|video|audio|mv|lyric\\s+video|lyrics\\s+video)|music\\s+video|lyric\\s+video|lyrics\\s+video|官方\\s*(?:mv|音樂錄影帶|音乐录影带|歌詞影片|歌词影片))"
        let bracketed = "(?:\(bare)|官方頻道|官方频道)"
        let suffix = "(?i)(?:\\s*\\(\\s*\(bracketed)\\s*\\)|\\s*\\[\\s*\(bracketed)\\s*\\]|\\s*【\\s*\(bracketed)\\s*】|\\s+\(bare))\\s*$"
        while let range = lookupTitle.range(of: suffix, options: .regularExpression) {
            let preceding = String(lookupTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized(preceding).hasSuffix("unofficial") else { break }
            lookupTitle = preceding
        }
        guard !lookupTitle.isEmpty, !lookupArtist.isEmpty,
              normalized(lookupTitle) != normalized(title) || normalized(lookupArtist) != normalized(artist) else { return nil }
        return Pair(title: lookupTitle, artist: lookupArtist)
    }

    private static func hasGuestCredit(_ value: String) -> Bool {
        let text = normalized(value)
        return text.contains(where: { "&+×/,、|".contains($0) })
            || text.range(of: "\\b(feat|featuring|ft|with|vs|versus)\\b", options: .regularExpression) != nil
    }
}
