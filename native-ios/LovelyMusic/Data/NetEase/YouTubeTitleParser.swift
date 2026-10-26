import Foundation

/// Guesses (artist, song) from a YouTube title such as
/// `風小箏 - 別丟下我不管「高音質 x 動態歌詞 Lyrics」♪ SDPMusic ♪` or
/// `徐佳瑩 LaLa【到此為止 From Now On】Official Music Video`.
/// Rules were tuned against 120 random songs of the user's playlist (2026-10-26).
enum YouTubeTitleParser {
    struct Guess: Equatable {
        let artist: String
        let song: String
    }

    /// Video packaging words; a bracket containing one is never the song.
    static let noise = #"(?i)official|music\s*video|lyric|(?<![a-z])mv(?![a-z])|(?<![a-z])hd(?![a-z])|(?<![a-z])4k(?![a-z])|ktv|visuali[sz]er|官方|完整|高音質|高音质|高清|超清|動態|动态|歌詞|歌词|字幕|無損|无损|(?<![a-z])sub(?![a-z])|vietsub|原唱|翻唱|cover|主題曲|主题曲|片尾曲?|片頭曲?|片头曲?|插曲|推廣|推广|主打|(?<![a-z])ost(?![a-z])|電視劇|电视剧|電影|电影|影视剧|影視劇|網游|网游|chapter|remaster|\.f4v|sdpmusic|純享|纯享|原版|live\s+from"#
    /// 《劇名》 followed by one of these names a drama, not the song.
    static let workSuffix = #"^\s*(?:主題曲|主题曲|片尾曲|片頭曲|片头曲|插曲|主題推廣曲|主题推广曲|片頭主題曲|片头主题曲)"#
    private static let opening: [Character: Character] = [
        "【": "】", "《": "》", "「": "」", "『": "』", "[": "]", "（": "）", "(": ")", "〔": "〕", "〈": "〉"]

    private struct Segment {
        let opener: Character?   // nil for plain text
        let body: String
    }

    private static func segments(_ title: String) -> [Segment] {
        var result: [Segment] = []
        var depth = 0
        var buffer = ""
        var opener: Character?
        var closer: Character?
        for character in title {
            if depth == 0, let close = opening[character] {
                if !buffer.trimmingCharacters(in: .whitespaces).isEmpty { result.append(.init(opener: nil, body: buffer)) }
                buffer = ""; opener = character; closer = close; depth = 1
            } else if depth > 0, opening[character] != nil {
                depth += 1; buffer.append(character)
            } else if depth > 0, character == closer || opening.values.contains(character) {
                depth -= 1
                if depth == 0 { result.append(.init(opener: opener, body: buffer)); buffer = "" }
                else { buffer.append(character) }
            } else {
                buffer.append(character)
            }
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(.init(opener: depth == 0 ? nil : opener, body: buffer))
        }
        return result
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isLyricQuote(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.count >= 8 && matches(#"[，,。！？!? ]"#, value)
    }

    /// Leading CJK part of a bilingual credit: 徐佳瑩 LaLa -> 徐佳瑩.
    static func cjkLead(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(
            of: #"^[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^A-Za-z]*?(?=\s*[A-Za-z])"#,
            options: .regularExpression) else { return trimmed }
        let lead = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? trimmed : lead
    }

    static func tidy(_ text: String) -> String {
        var value = text.replacingOccurrences(of: noise, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[♪♫♬·•]|\b(?:19|20)\d\d\b"#, with: " ", options: .regularExpression)
        value = value.components(separatedBy: CharacterSet(charactersIn: "|｜")).first ?? ""
        value = value.components(separatedBy: CharacterSet(charactersIn: "，,")).first ?? ""
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_\"'“”:：."))
    }

    private static func splitOnDash(_ text: String) -> [String] {
        for pattern in [#"\s+[-–—]{1,2}\s+"#, #"[-–—]{1,2}"#] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return [String(text[..<range.lowerBound]), String(text[range.upperBound...])]
            }
        }
        return [text]
    }

    /// Ordered guesses; the artist may be empty when the title has none.
    static func guesses(_ title: String) -> [Guess] {
        let parts = segments(title)
        var bracketSong: (song: String, credit: String)?
        var kept: [String] = []
        for (index, segment) in parts.enumerated() {
            let body = segment.body.trimmingCharacters(in: .whitespaces)
            guard let opener = segment.opener else { kept.append(body); continue }
            let following = index + 1 < parts.count && parts[index + 1].opener == nil ? parts[index + 1].body : ""
            if "『「".contains(opener), isLyricQuote(body) { continue }             // quoted lyric line
            if matches(noise, body) || matches(workSuffix, following) { continue } // packaging or 《劇名》主題曲
            if "《【[〈".contains(opener), bracketSong == nil, body.count <= 40 {
                bracketSong = (body, kept.joined(separator: " "))                    // 《歌名》 after its credit
                continue
            }
            kept.append(body)
        }
        let text = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var result: [Guess] = []
        func add(_ artist: String, _ song: String) {
            let guess = Guess(artist: cjkLead(tidy(artist)), song: tidy(song))
            if !guess.song.isEmpty, !result.contains(guess) { result.append(guess) }
        }
        let dash = splitOnDash(text)
        let hasDash = dash.count == 2 && !tidy(dash[0]).isEmpty && !tidy(dash[1]).isEmpty
        if let bracketSong, !hasDash { add(bracketSong.credit, bracketSong.song) }
        if hasDash { add(dash[0], dash[1]); add(dash[1], dash[0]) }
        if let bracketSong { add(bracketSong.credit, bracketSong.song) }
        let words = tidy(text).split(separator: " ").map(String.init)
        if words.count == 2 { add(words[0], words[1]); add(words[1], words[0]) }
        add("", text)
        return result
    }

    /// 到此為止 From Now On -> [到此為止 From Now On, 到此為止].
    static func songVariants(_ song: String) -> [String] {
        guard matches(#"^\p{Han}"#, song) else { return [song] }
        let lead = cjkLead(song)
        return lead == song ? [song] : [song, lead]
    }

    // MARK: Matching

    static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: true) ?? text
    }

    static func normalized(_ text: String) -> String {
        simplified(text).lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Title without bracketed suffixes: 千年（回忆版） -> 千年.
    static func bareTitle(_ text: String) -> String {
        normalized(text.replacingOccurrences(of: #"[(（\[【][^)）\]】]*[)）\]】]"#, with: "", options: .regularExpression))
    }

    static func artistParts(_ text: String) -> Set<String> {
        let separated = text.replacingOccurrences(
            of: #"(?i)[/&,、+]|\s+x\s+|\bfeat\.?|\bft\.?"#, with: "|", options: .regularExpression)
        return Set(separated.split(separator: "|").map { normalized(String($0)) }.filter { !$0.isEmpty })
    }

    /// Covers, live takes and alternate versions, unless the video title says so too.
    static let versionWords = #"(?i)cover|翻唱|伴奏|instrumental|karaoke|remix|(?<![a-z])dj(?![a-z])|live|现场|現場|a\s*cap+ella|版|demo|acoustic|女声|男声|女聲|男聲|合唱"#

    struct Record {
        let title: String
        let artist: String
        let duration: Double?
    }

    /// The record for this song, preferring the closest length; nil if none is the same song.
    static func bestMatch(_ records: [Record], guess: Guess, videoTitle: String, videoDuration: Int?,
                          titleHasArtist: Bool) -> Record? {
        let wanted = bareTitle(guess.song)
        guard !wanted.isEmpty else { return nil }
        let videoIsVersion = matches(versionWords, videoTitle)
        var candidates = records.filter {
            bareTitle($0.title) == wanted && (videoIsVersion || !matches(versionWords, $0.title + " " + $0.artist))
        }
        if !guess.artist.isEmpty {
            let expected = artistParts(guess.artist)
            candidates = candidates.filter { !artistParts($0.artist).isDisjoint(with: expected) }
        } else if titleHasArtist {
            return nil
        } else {
            // No artist in the title: only a same-length recording identifies the song.
            guard let videoDuration else { return nil }
            candidates = candidates.filter { $0.duration.map { abs($0 - Double(videoDuration)) <= 3 } ?? false }
        }
        guard let videoDuration else { return candidates.first }
        return candidates.min { lhs, rhs in
            abs((lhs.duration ?? .infinity) - Double(videoDuration)) < abs((rhs.duration ?? .infinity) - Double(videoDuration))
        }
    }
}
