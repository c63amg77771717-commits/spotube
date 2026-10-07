import Foundation

enum LyricsLookupMetadata {
    struct Pair {
        let title: String
        let artist: String
    }

    struct NormalizationStep {
        enum Reason: String { case separatorPresentation, lyricPresentation, soundtrackPresentation, videoPresentation, explicitSongSpan, creditRoles, uncertainRoleAlternative, chineseCleaner }
        let before: String
        let after: String
        let reason: Reason
    }

    /// Every changed stage retains its exact input/output and operation reason.
    /// Whole original metadata stays in LyricsLookupContext and the literal hypothesis.
    static func normalizationSteps(context: LyricsLookupContext, pair: Pair) -> [NormalizationStep] {
        guard context.hasYouTubeOrigin else { return [] }
        var value = context.title
        var steps: [NormalizationStep] = []
        func apply(_ next: String, _ reason: NormalizationStep.Reason) {
            guard next != value else { return }
            steps.append(.init(before: value, after: next, reason: reason)); value = next
        }
        apply(ChineseLyricsMetadataCleaner.preparedTitle(value, suppliedArtist: context.artist), .chineseCleaner)
        apply(value.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression), .separatorPresentation)
        apply(strippingChineseLyricPresentation(value), .lyricPresentation)
        for _ in 0..<8 {
            let previous = value
            apply(strippingSoundtrackPresentation(value), .soundtrackPresentation)
            apply(strippingPresentationSuffix(value), .videoPresentation)
            if value == previous { break }
        }
        if let credit = bracketedVideoCredit(value) { apply(credit.title, .explicitSongSpan) }
        if value != pair.title { apply(pair.title, .creditRoles) }
        return Array(steps.prefix(20))
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
        ChineseLyricsMetadataCleaner.roles(context)
    }

    static func videoCreditPairsLegacy(_ context: LyricsLookupContext) -> [Pair] {
        guard context.hasYouTubeOrigin else { return [] }
        let explicit = strippingVideoPresentation(strippingChineseLyricPresentation(context.title))
        // A bounded song span already establishes the roles. Do not re-split
        // its bilingual performer or song title into a whitespace hypothesis.
        guard bracketedVideoCredit(explicit) == nil else { return [] }
        var input = context.title.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression)
        input = strippingChineseLyricPresentation(input)
        input = strippingPresentationSuffix(input)
        input = strippingSoundtrackPresentation(input)
        var pieces = input.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if pieces.count == 1 {
            let presented = strippingChineseLyricPresentation(context.title)
            // Whitespace is not credit syntax for a bare bilingual title or Live
            // version. Only an observed official/publisher MV suffix permits this
            // uncertain hypothesis, which still requires manual confirmation.
            guard strippingPresentationSuffix(presented) != presented else { return [] }
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
        let presented = strippingChineseLyricPresentation(title)
        guard bracketedVideoCredit(strippingVideoPresentation(presented)) == nil,
              strippingPresentationSuffix(presented) != presented else { return false }
        let input = strippingSoundtrackPresentation(strippingPresentationSuffix(presented))
        guard !input.contains(" - "), !input.contains("《"), !input.contains("【") else { return false }
        return input.range(of: "^([\\p{Han}]{2,4})\\s+(.+)$", options: .regularExpression) != nil
    }

    static func quotedVideoPair(_ context: LyricsLookupContext) -> Pair? {
        guard context.hasYouTubeOrigin else { return nil }
        let bounded = boundedQueryPresentation(context.title)
        if bounded != context.title,
           context.title.range(of: "(?:「[^」\\r\\n]{12,240}」|『[^』\\r\\n]{12,240}』)\\s*$", options: .regularExpression) != nil {
            let parts = context.title.components(separatedBy: " - ")
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                return Pair(title: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                            artist: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
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

    static func cleaned(title: String, artist: String, allowVideoCredits: Bool,
                        allowArtistReplacement: Bool = false) -> Pair? {
        // The explicit legacy uploader compatibility route retains its previous behavior.
        if allowArtistReplacement || !allowVideoCredits {
            return cleanedLegacy(title: title, artist: artist, allowVideoCredits: allowVideoCredits,
                                 allowArtistReplacement: allowArtistReplacement)
        }
        let pair = ChineseLyricsMetadataCleaner.analyze(.init(title: title, artist: artist, hasYouTubeOrigin: true)).pair
        guard !pair.title.isEmpty, !pair.artist.isEmpty,
              pair.title != title || pair.artist != artist else { return nil }
        return pair
    }

    static func cleanedLegacy(title: String, artist: String, allowVideoCredits: Bool,
                              allowArtistReplacement: Bool = false) -> Pair? {
        var lookupInput = title
        var boundedCredit: Pair?
        if allowVideoCredits {
            lookupInput = lookupInput.replacingOccurrences(of: " [–—－] ", with: " - ", options: .regularExpression)
            lookupInput = strippingVideoPresentation(strippingChineseLyricPresentation(lookupInput))
            if let credit = bracketedVideoCredit(lookupInput) {
                boundedCredit = credit
                lookupInput = credit.artist + " - " + credit.title
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
                let suppliedPrimary = LyricsCanonicalMetadata.creditComponents(lookupArtist).first.map {
                    identityKey($0) == identityKey(credit)
                } == true
                guard allowVideoCredits, boundedX || boundedCredit != nil || (!hasGuestCredit(credit) && suppliedPrimary) else { return nil }
            }
            let track = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowVideoCredits, !lookupArtist.isEmpty,
               identityKey(track) == identityKey(lookupArtist),
               identityKey(credit) != identityKey(lookupArtist) {
                lookupTitle = credit
                lookupArtist = track
            } else if normalized(credit) == normalized(lookupArtist) || allowVideoCredits {
                lookupTitle = track
                // A supplied performer remains a constraint. A weak video title
                // can propose a track, but cannot turn another name into fact.
                if lookupArtist.isEmpty || allowArtistReplacement { lookupArtist = credit }
            } else { return nil }
        }
        if parts.count == 1, allowVideoCredits {
            let video = LyricsLookupContext(title: title, artist: lookupArtist, hasYouTubeOrigin: true)
            if let hypothesis = videoCreditPairs(video).first {
                lookupTitle = hypothesis.title
                if lookupArtist.isEmpty { lookupArtist = hypothesis.artist }
            }
        }
        lookupTitle = strippingPresentationSuffix(lookupTitle)
        if allowVideoCredits {
            lookupTitle = strippingChineseLyricPresentation(lookupTitle)
            lookupTitle = strippingVideoPresentation(lookupTitle)
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

    static func strippingChineseLyricPresentation(_ input: String, removePrecedingSnippet: Bool = true) -> String {
        let versions = "(?i)\\b(?:live|remix|cover|acoustic|instrumental|karaoke)\\b|翻唱|现场|現場|演唱会|演唱會|改编|改編|加速|慢速"
        guard input.range(of: versions, options: .regularExpression) == nil else { return input }
        let words = "(?:動態歌詞|动态歌词|非官方歌詞|非官方歌词|lyrics?\\s*(?:video)?)(?:\\s*[/|]\\s*(?:Vietsub|Pinyin\\s*Lyrics?|高音質|高音质|High\\s*Quality))*"
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
                .replacingOccurrences(of: "[♫♪]+\\s*$", with: "", options: .regularExpression)
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

    /// Locate the first song span by source position, never by bracket type.
    /// Later work titles inside soundtrack notes cannot become performer credits.

    /// Observed presentation boundaries only; not a song or performer alias database.
    static func boundedQueryPresentation(_ input: String) -> String {
        var value = input.replacingOccurrences(of: " [–—－─━] ", with: " - ", options: .regularExpression)
        let bracketLabel = "(?:【([^】\\r\\n]{1,120})】|\\[([^\\]\\r\\n]{1,120})\\])\\s*$"
        if let regex = try? NSRegularExpression(pattern: bracketLabel),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let whole = Range(match.range, in: value),
           let body = (1..<match.numberOfRanges).compactMap({ Range(match.range(at: $0), in: value) }).first,
           isPresentationOnlySpan(String(value[body])), strippingChineseLyricPresentation(value) == value {
            let prefix = String(value[..<whole.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                value = prefix
                // A visually separated bar after an observed label is still an uncertain role.
                value = value.replacingOccurrences(of: "^([\\p{Han}]{2,4}\\s+[A-Za-z][A-Za-z .'-]{0,40})\\s+[lI|]\\s+(.+)$",
                    with: "$1 - $2", options: .regularExpression)
            }
        }
        // An explicit phonetic label, bounded snippet, and Latin presentation footer.
        // Unknown prose, versions and unmatched brackets do not meet this contract.
        let phonetic = "(?i)\\s+(?:拼音歌詞|拼音歌词)\\s*【[^】\\r\\n]{1,240}】(?=[A-Za-z ]*(?:lyrics?|pin\\s*yin))[A-Za-z ]{1,120}\\s*$"
        if let range = value.range(of: phonetic, options: .regularExpression),
           LyricsCanonicalMetadata.versions(String(value[range])).isEmpty {
            let prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.contains(" - "), !prefix.isEmpty { value = prefix }
        }
        // Long sentence-like quotes after an unquoted song are lyric snippets.
        // A quote-only title, short formal subtitle, unknown suffix and version stay literal.
        let snippet = "(?:「[^」\\r\\n]{12,240}」|『[^』\\r\\n]{12,240}』)\\s*$"
        if let range = value.range(of: snippet, options: .regularExpression),
           String(value[range]).range(of: "[，,。！？!?]", options: .regularExpression) != nil,
           LyricsCanonicalMetadata.versions(String(value[range])).isEmpty {
            let prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = prefix.components(separatedBy: " - ")
            if pieces.count == 2, !pieces[1].isEmpty,
               !prefix.contains("「"), !prefix.contains("『") { value = prefix }
        }
        // Only a bounded sentence about performance/presentation after a formal song span.
        let narration = "[，,](?=[^\\r\\n]{1,120}(?:歌聲|歌声|動聽|动听|百聽|百听))[^\\r\\n]{1,160}[！!。]\\s*$"
        if value.contains("》"), let range = value.range(of: narration, options: .regularExpression),
           LyricsCanonicalMetadata.versions(String(value[range])).isEmpty {
            let prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasSuffix("》") { value = prefix }
        }
        return value
    }

    static func isPresentationOnlySpan(_ text: String) -> Bool {
        let label = "(?i)^(?:(?:高音質|高音质|High\\s*Quality)\\s*)?(?:動態歌詞|动态歌词|有歌詞字幕|有歌词字幕|歌詞版|歌词版|lyrics?)(?:\\s*(?:Lyrics?|MV|Video|Pinyin\\s*Lyrics?|Vietsub|[/|]))*$"
        return text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: label, options: .regularExpression) != nil
    }


    /// A duet caption can corroborate two complete returned names against the exact
    /// concatenated source credit. It never splits names by length or asserts a primary.
    /// The scorer always keeps this interpretation manual, even with an official MV.
    static func corroboratedDuetCredits(context: LyricsLookupContext, pair: Pair,
                                       returnedArtist: String) -> [String]? {
        guard context.hasYouTubeOrigin,
              context.artistNameSource == .uploader || context.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.title.contains("對唱") || context.title.contains("对唱") else { return nil }
        let prepared = boundedQueryPresentation(context.title)
        guard let explicit = bracketedVideoCredit(prepared),
              identityKey(explicit.title) == identityKey(pair.title),
              identityKey(explicit.artist) == identityKey(pair.artist),
              let opening = prepared.firstIndex(where: { "《〈『【[".contains($0) }) else { return nil }
        let prefix = String(prepared[..<opening]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cue = prefix.range(of: "(?:神級|神级)?(?:對唱|对唱)\\s*$", options: .regularExpression) else { return nil }
        let sourceNames = identityKey(String(prefix[..<cue.lowerBound]))
        guard sourceNames == identityKey(pair.artist) else { return nil }
        let credits = LyricsCanonicalMetadata.creditComponents(returnedArtist)
        let names = credits.map(identityKey)
        guard names.count == 2, Set(names).count == 2,
              names.allSatisfy({ (2...16).contains($0.count) && $0.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) } }),
              sourceNames == names.joined() || sourceNames == names.reversed().joined() else { return nil }
        return credits
    }

    static func bracketedVideoCredit(_ input: String) -> Pair? {
        let brackets: [(Character, Character)] = [("《", "》"), ("〈", "〉"), ("『", "』"), ("【", "】"), ("[", "]")]
        let spans = brackets.compactMap { open, close in balancedBracket(open, close, in: input) }
        guard let (open, close) = spans.min(by: { $0.0 < $1.0 }),
              !input[..<open].contains(" - ") else { return nil }
        let credit = String(input[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(?:神級|神级)?(?:對唱|对唱)$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*[-–—－/]\\s*$", with: "", options: .regularExpression)
        guard !credit.isEmpty, credit.count <= 128,
              !credit.contains(where: { "()（）《》〈〉『』【】[]".contains($0) }) else { return nil }
        let track = String(input[input.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty, track.count <= 256, !isPresentationOnlySpan(track) else { return nil }
        // [Live] / [Official MV] on a bare title is not a song-credit span.
        if input[open] == "[" || input[open] == "〈" {
            guard track.range(of: "(?i)^(?:live|remix|acoustic|instrumental|karaoke|cover)(?:\\s+(?:live|remix|acoustic|instrumental|karaoke|cover))*$", options: .regularExpression) == nil,
                  strippingPresentationSuffix(track) == track,
                  normalized(track) != "official mv", normalized(track) != "lyrics mv" else { return nil }
        }
        let tail = String(input[input.index(after: close)...])
        let remainder = strippingVideoPresentation(tail, allowEmpty: true).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a complete named-work role after an explicit song span can be
        // presentation. Unknown prose and version-bearing suffixes survive.
        let suffix = unbracketedSoundtrackNote(remainder) ? "" : remainder
        return Pair(title: track + (suffix.isEmpty ? "" : " " + suffix), artist: credit)
    }

    /// Alternating bounded standalone labels may follow a song span in either order.
    /// The song span and version-bearing text are retained.
    static func strippingVideoPresentation(_ input: String, allowEmpty: Bool = false) -> String {
        let standalone = "(?i)^(?:MV|official\\s+(?:music\\s+video|video|audio|mv)|官方\\s*MV)$"
        if allowEmpty, input.trimmingCharacters(in: .whitespacesAndNewlines).range(of: standalone, options: .regularExpression) != nil { return "" }
        var value = input.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        for _ in 0..<8 {
            let next = strippingPresentationSuffix(strippingSoundtrackPresentation(value))
            if next == value || (!allowEmpty && next.isEmpty) { break }
            value = next
        }
        return value
    }

    private static func soundtrackNote(_ text: String) -> Bool {
        guard text.count <= 240, LyricsCanonicalMetadata.versions(text).isEmpty else { return false }
        let role = "(?:電視劇|电视剧|電影|电影|插曲|主題曲|主题曲|推廣曲|推广曲)"
        // A named work plus explicit role, Chinese role plus OST, or a bounded
        // foreign OST translation footer with a pipe establishes presentation.
        let pattern = "(?i)(?:\(role).*?[《【].*?[》】]|[《【].*?[》】].*?\(role)|\(role).*?\\bOST\\b|\\bOST\\b.*?\(role)|\\bOST\\b.*?\\|)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func unbracketedSoundtrackNote(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 240, LyricsCanonicalMetadata.versions(text).isEmpty else { return false }
        let medium = "(?:[\\p{Han}]{0,8}(?:華劇|华剧|台劇|台剧|電視劇|电视剧|電影|电影|劇集|剧集))"
        let work = "(?:《[^《》\\r\\n]{1,80}》|〈[^〈〉\\r\\n]{1,80}〉|【[^【】\\r\\n]{1,80}】)"
        let role = "(?:插曲|主題曲|主题曲|片頭曲|片头曲|片尾曲|推廣曲|推广曲|宣傳曲|宣传曲)"
        let qualifier = "(?:情感|情緒|情绪|人物)?"
        let pattern = "(?i)^(?:" + medium + "\\s*" + work + "|" + work + "(?:\\s*" + medium + ")?)\\s*" + qualifier + role + "(?:\\s+OST)?$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func strippingSoundtrackPresentation(_ input: String) -> String {
        let suffix = "(?i)\\s*(?:【\\s*《[^》]{1,80}》(?:電視劇|电视剧)(?:情感)?(?:主題曲|主题曲)\\s*】|[（(](?:電影|电影)《[^》]{1,80}》(?:推廣曲|推广曲|主題曲|主题曲)[）)])\\s*$"
        var value = input
        let brackets: [(Character, Character)] = [("（", "）"), ("(", ")"), ("【", "】"), ("[", "]")]
        for _ in 0..<8 {
            guard let (open, close) = brackets.compactMap({ a, b in balancedBracket(a, b, in: value) })
                .first(where: { value.index(after: $0.1) == value.endIndex }),
                  soundtrackNote(String(value[value.index(after: open)..<close])) else { break }
            value = String(value[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        let bare = "(?:歌詞版Lyrics\\s*MV|歌词版Lyrics\\s*MV|official\\s+(?:music\\s+video|video|audio|mv|lyric\\s+video|lyrics\\s+video)|music\\s+video|ミュージックビデオ|lyrics?\\s+mv|lyric\\s+video|lyrics\\s+video|官方\\s*(?:mv|音樂錄影帶|音乐录影带|歌詞影片|歌词影片))"
        let bracketed = "(?:\(bare)|官方頻道|官方频道)"
        let suffix = "(?i)(?:\\s*\\(\\s*\(bracketed)\\s*\\)|\\s*\\[\\s*\(bracketed)\\s*\\]|\\s*【\\s*\(bracketed)\\s*】|(?:\\s+|(?<=[》〉】』」\\]）)]))\(bare))\\s*$"
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
