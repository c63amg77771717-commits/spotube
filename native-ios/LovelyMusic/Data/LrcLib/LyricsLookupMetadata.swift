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

    /// Preserve both exact components when a verified video does not establish order.
    /// A supplied performer matching either side fixes the direction; never invent names.
    static func videoCreditPairs(_ context: LyricsLookupContext) -> [Pair] {
        guard context.hasYouTubeOrigin else { return [] }
        var input = context.title.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression)
        input = strippingChineseLyricPresentation(input)
        input = strippingPresentationSuffix(input)
        input = strippingSoundtrackPresentation(input)
        var pieces = input.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if pieces.count == 1 {
            // A bounded explicit Han credit followed by whitespace is an alternative
            // hypothesis, not a general split on every word in a song title.
            let pattern = "^([\\p{Han}]{2,4})\\s+([^《【]+)$"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let first = Range(match.range(at: 1), in: input),
               let second = Range(match.range(at: 2), in: input) {
                pieces = [String(input[first]), String(input[second])]
            }
        }
        guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty }) else { return [] }
        let forward = Pair(title: pieces[1], artist: pieces[0])
        let reverse = Pair(title: pieces[0], artist: pieces[1])
        let artist = identityKey(context.artist)
        if !artist.isEmpty {
            if identityKey(forward.artist) == artist { return [forward] }
            if identityKey(reverse.artist) == artist { return [reverse] }
        }
        return [forward, reverse]
    }

    static func isWhitespaceVideoCredit(_ title: String) -> Bool {
        let input = strippingSoundtrackPresentation(strippingPresentationSuffix(strippingChineseLyricPresentation(title)))
        guard !input.contains(" - "), !input.contains("《"), !input.contains("【") else { return false }
        return input.range(of: "^([\\p{Han}]{2,4})\\s+(.+)$", options: .regularExpression) != nil
    }

    static func quotedVideoPair(_ context: LyricsLookupContext) -> Pair? {
        guard context.hasYouTubeOrigin else { return nil }
        var input = strippingChineseLyricPresentation(context.title, removePrecedingSnippet: false)
        guard input != context.title, input.contains("「") || input.contains("『") else { return nil }
        input = strippingSoundtrackPresentation(strippingPresentationSuffix(input))
        let parts = input.components(separatedBy: " - ")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return Pair(title: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
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
            lookupInput = strippingSoundtrackPresentation(lookupInput)
            let songBrackets: [(Character, Character)] = [("《", "》"), ("【", "】")]
            for (opening, closing) in songBrackets {
                guard let (open, close) = balancedBracket(opening, closing, in: lookupInput), open < close,
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
            guard !credit.isEmpty else { return nil }
            if hasGuestCredit(credit) || hasGuestCredit(lookupArtist) {
                // An explicit bounded x credit is retained as a collaboration. Never
                // invent missing artists from an ambiguous A & B upload title.
                let boundedX = credit.range(of: "\\s+x\\s+", options: .regularExpression) != nil
                guard allowVideoCredits, boundedX else { return nil }
            }
            let track = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowVideoCredits, !lookupArtist.isEmpty,
               identityKey(track) == identityKey(lookupArtist),
               identityKey(credit) != identityKey(lookupArtist) {
                lookupTitle = credit
                lookupArtist = track
            } else if normalized(credit) == normalized(lookupArtist) || allowVideoCredits {
                lookupTitle = track
                lookupArtist = credit
            } else { return nil }
        }
        if parts.count == 1, allowVideoCredits {
            let video = LyricsLookupContext(title: lookupInput, artist: lookupArtist, hasYouTubeOrigin: true)
            if let hypothesis = videoCreditPairs(video).first {
                lookupTitle = hypothesis.title
                lookupArtist = hypothesis.artist
            }
        }
        lookupTitle = strippingPresentationSuffix(lookupTitle)
        if allowVideoCredits {
            lookupTitle = strippingChineseLyricPresentation(lookupTitle)
            lookupTitle = strippingSoundtrackPresentation(lookupTitle)
        }
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

    private static func strippingChineseLyricPresentation(_ input: String, removePrecedingSnippet: Bool = true) -> String {
        let versions = "(?i)\\b(?:live|remix|cover|acoustic|instrumental|karaoke)\\b|翻唱|现场|現場|演唱会|演唱會|改编|改編|加速|慢速"
        guard input.range(of: versions, options: .regularExpression) == nil else { return input }
        let words = "(?:(?:動態歌詞|动态歌词)(?:\\s*/\\s*PinyinLyrics)?|非官方歌詞|非官方歌词|lyrics?\\s*(?:video)?)"
        let label = "(?:【\\s*\(words)\\s*】|『\\s*\(words)\\s*』|（\\s*\(words)\\s*）|\\(\\s*\(words)\\s*\\)|\\[\\s*\(words)\\s*\\]|官方動態歌詞版|官方动态歌词版)"
        let quote = "(?:『[^』]*』|「[^」]*」|◖[^◗]*◗)"
        // A paired = caption and recognized language/music footer is presentation,
        // only when it follows an entire explicit lyric label. Unbounded prose survives.
        let caption = "(?:\\s*=\\s*[^=\\r\\n]{1,240}\\s*=\\s*(?:Chinese\\s+music\\s*~?)?)?"
        let suffix = "(?i)\\s*\(label)(?:\\s*(?:\(quote)|[♫♪]))*\(caption)\\s*$"
        var value = input
        while let range = value.range(of: suffix, options: .regularExpression) {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if removePrecedingSnippet, value != input,
           let quoteRange = value.range(of: "(?:『[^』]*』|「[^」]*」)\\s*$", options: .regularExpression) {
            let prefix = String(value[..<quoteRange.lowerBound])
            let pieces = prefix.components(separatedBy: " - ")
            // A quote-only formal title is protected. Only a trailing snippet after
            // an unquoted nonempty track and an explicit lyric label can be removed.
            if pieces.count == 2, !pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !prefix.contains("「"), !prefix.contains("『") { value = prefix.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return value.isEmpty ? input : value
    }

    private static func balancedBracket(_ opening: Character, _ closing: Character, in value: String) -> (String.Index, String.Index)? {
        guard let start = value.firstIndex(of: opening) else { return nil }
        var depth = 0
        for index in value.indices where index >= start {
            if value[index] == opening { depth += 1 }
            if value[index] == closing {
                depth -= 1
                if depth == 0 { return (start, index) }
            }
        }
        return nil
    }

    private static func strippingSoundtrackPresentation(_ input: String) -> String {
        let suffix = "(?i)\\s*(?:【\\s*《[^》]{1,80}》(?:電視劇|电视剧)(?:情感)?(?:主題曲|主题曲)\\s*】|[（(](?:電影|电影)《[^》]{1,80}》(?:推廣曲|推广曲|主題曲|主题曲)[）)])\\s*$"
        var value = input
        while let range = value.range(of: suffix, options: .regularExpression) {
            let prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { break }
            value = prefix
        }
        return value
    }

    private static func strippingPresentationSuffix(_ input: String) -> String {
        var value = input
        let channelSuffix = "(?i)\\s*[-–—]\\s*[\\p{Han}A-Za-z]{1,16}official\\s+(?:HQ|HD)官方版MV\\s*$"
        if let range = value.range(of: channelSuffix, options: .regularExpression) {
            let prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { value = prefix }
        }
        let bare = "(?:official\\s+(?:music\\s+video|video|audio|mv|lyric\\s+video|lyrics\\s+video)|music\\s+video|lyrics?\\s+mv|lyric\\s+video|lyrics\\s+video|官方\\s*(?:mv|音樂錄影帶|音乐录影带|歌詞影片|歌词影片))"
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
            || text.range(of: "\\b(feat|featuring|ft|with|vs|versus)\\b|\\s+x\\s+", options: .regularExpression) != nil
    }
}
