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
