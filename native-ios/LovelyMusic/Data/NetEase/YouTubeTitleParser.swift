import Foundation

/// Guesses (artist, song) from a YouTube title such as
/// `風小箏 - 別丟下我不管「高音質 x 動態歌詞 Lyrics」♪ SDPMusic ♪` or
/// `徐佳瑩 LaLa【到此為止 From Now On】Official Music Video`, and decides whether a
/// catalog record is the same song. Rules mirror the offline replica measured on
/// 300 random songs of the user's playlist (2026-10-27).
enum YouTubeTitleParser {
    struct Guess: Equatable {
        let artist: String
        let song: String
    }

    /// Video packaging words; a bracket containing one is never the song.
    static let noise = #"(?i)official|music\s*video|lyric|(?<![a-z])mv(?![a-z])|(?<![a-z])hd(?![a-z])|(?<![a-z])4k(?![a-z])|ktv|visuali[sz]er|官方|完整|高音質|高音质|高清|超清|動態|动态|歌詞|歌词|字幕|無損|无损|(?<![a-z])sub(?![a-z])|vietsub|原唱|翻唱|cover|主題曲|主题曲|片尾曲?|片頭曲?|片头曲?|插曲|推廣|推广|主打|(?<![a-z])ost(?![a-z])|電視劇|电视剧|電影|电影|影视剧|影視劇|網游|网游|chapter|remaster|\.f4v|sdpmusic|純享|纯享|原版|live\s+from|(?<![a-z])hq(?![a-z])"#
    static let extraNoise = #"(?i)正式版|完整放映|放映|飯制|饭制|特別演出\S*|特别演出\S*|新專輯\S*|新专辑\S*|已上市|\b\d{3,4}p\b|手遊|手游|主打歌|youtube"#
    /// 《劇名》 followed by one of these names a drama, not the song.
    static let workSuffix = #"^\s*(?:主題曲|主题曲|片尾曲|片頭曲|片头曲|插曲|主題推廣曲|主题推广曲|片頭主題曲|片头主题曲)"#
    /// Credit separators, strongest first: `A - B` (or `A ~ B`), `A / B`, `A l B`, `A-B`.
    private static let separators = [#"\s+[-–—~～]{1,2}\s+"#, #"\s+/\s+"#, #"\s+[l|｜]\s+"#, #"[-–—]{1,2}"#]
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

    /// Leading CJK part of a bilingual credit: 徐佳瑩 LaLa -> 徐佳瑩, 黑夜問白天 53 Dawns -> 黑夜問白天.
    static func cjkLead(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(
            of: #"^[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}][^A-Za-z0-9]*?(?=\s*[A-Za-z]|\s+[0-9])"#,
            options: .regularExpression) else { return trimmed }
        let lead = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? trimmed : lead
    }

    static func tidy(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\s=.*$"#, with: " ", options: .regularExpression)   // =lyric= tails
        value = value.replacingOccurrences(of: #"\s+[-–—]\S.*$"#, with: " ", options: .regularExpression) // 大火 -華納 label tails
        value = value.replacingOccurrences(of: #"(?i)\s+(?:feat|ft)\.?\s.*$"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: noise, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: extraNoise, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[♪♫♬·•]|\b(?:19|20)\d\d\b"#, with: " ", options: .regularExpression)
        value = value.components(separatedBy: CharacterSet(charactersIn: "|｜")).first ?? ""
        value = value.components(separatedBy: CharacterSet(charactersIn: "，,")).first ?? ""
        // Leftovers of 動態歌詞版 / 歌詞版 once the packaging words are gone.
        value = value.replacingOccurrences(of: #"(?:(?<=\s)|^)(?:版|歌|版本)(?=\s|$)"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_\"'“”:：.="))
    }

    /// Splits at the strongest separator whose both sides keep content.
    private static func splitCredit(_ text: String) -> (parts: [String], separator: Int?) {
        for (index, pattern) in separators.enumerated() {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let parts = [String(text[..<range.lowerBound]), String(text[range.upperBound...])]
            if !tidy(parts[0]).isEmpty, !tidy(parts[1]).isEmpty { return (parts, index) }
        }
        return ([text], nil)
    }

    /// Ordered guesses; the artist may be empty when the title has none.
    static func guesses(_ rawTitle: String) -> [Guess] {
        let title = rawTitle.replacingOccurrences(of: "[\u{200B}-\u{200F}\u{202A}-\u{202E}\u{2066}-\u{2069}]",
                                                  with: " ", options: .regularExpression)
        let parts = segments(title)
        var bracketSong: (song: String, credit: String)?
        var kept: [String] = []
        for (index, segment) in parts.enumerated() {
            let body = segment.body.trimmingCharacters(in: .whitespaces)
            guard let opener = segment.opener else { kept.append(body); continue }
            let following = index + 1 < parts.count && parts[index + 1].opener == nil ? parts[index + 1].body : ""
            let keptText = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if "『「".contains(opener), isLyricQuote(body) || (body.count >= 8 && !keptText.isEmpty) {
                continue                                                           // quoted lyric line
            }
            if "(（".contains(opener), matches("[A-Za-z]", body), !matches(#"\p{Han}"#, body), matches(#"\p{Han}"#, keptText) {
                continue                                                           // 大火(Jess Lee - Burn): English translation
            }
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
        func add(_ rawArtist: String, _ rawSong: String) {
            var artist = tidy(rawArtist)
            let credit = splitCredit(artist)
            if let separator = credit.separator, separator <= 1 { artist = tidy(credit.parts[0]) }  // 黃禮格 - 黃禮格《失眠》
            let guess = Guess(artist: artist, song: tidy(rawSong))
            guard !guess.song.isEmpty, normalized(guess.artist) != normalized(guess.song),
                  !result.contains(guess) else { return }
            result.append(guess)
        }
        let dash = splitCredit(text)
        let hasDash = dash.separator != nil
        if let bracketSong {
            let creditSplit = splitCredit(bracketSong.credit).separator
            let creditIsClean = !tidy(bracketSong.credit).isEmpty && !(creditSplit.map { $0 <= 1 } ?? false)
            if tidy(bracketSong.credit).isEmpty, !tidy(text).isEmpty, !hasDash {
                add(text, bracketSong.song)                                        // 《是你》张靓颖/王赫野
            }
            if !hasDash || creditIsClean { add(bracketSong.credit, bracketSong.song) }  // 張靚穎【幻紗之靈】… -《遊戲》
        }
        if hasDash { add(dash.parts[0], dash.parts[1]); add(dash.parts[1], dash.parts[0]) }
        if let bracketSong { add(bracketSong.credit, bracketSong.song) }
        let words = tidy(text).split(separator: " ").map(String.init)
        if words.count == 2 { add(words[0], words[1]); add(words[1], words[0]) }
        // A Lin 幸福了 然後呢: a leading Latin name before CJK words.
        if !hasDash, bracketSong == nil,
           let range = tidy(text).range(of: #"^[A-Za-z][A-Za-z .'-]{0,30}?\s+(?=\p{Han})"#, options: .regularExpression) {
            let whole = tidy(text)
            add(String(whole[range]), String(whole[range.upperBound...]))
        }
        add("", text)
        return result.map { Guess(artist: cjkLead($0.artist), song: $0.song) }
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

    private static let genericArtistWords: Set<String> = ["the", "band", "official", "music", "feat", "ft", "with"]

    /// Comparable artist parts: each CJK run and each whole Latin name.
    /// `G.E.M. 鄧紫棋` -> {gem, 邓紫棋, gem邓紫棋}; `李毓芬 Tia Lee` -> {李毓芬, tialee, …}.
    static func artistParts(_ text: String) -> Set<String> {
        let separated = simplified(text).replacingOccurrences(
            of: #"(?i)[/&,、+=]|\s+x\s+|\s和\s|\bfeat\.?|\bft\.?"#, with: "|", options: .regularExpression)
        var parts = Set<String>()
        let isShort: (String) -> Bool = { $0.range(of: #"^[a-z0-9]{1,2}$"#, options: .regularExpression) != nil }
        for credit in separated.split(separator: "|").map(String.init) {
            var cursor = credit.startIndex
            while let range = credit.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+|[A-Za-z0-9][A-Za-z0-9 .'-]*"#,
                                           options: .regularExpression, range: cursor..<credit.endIndex) {
                let key = normalized(String(credit[range]))
                if !key.isEmpty, !genericArtistWords.contains(key), !isShort(key) { parts.insert(key) }
                // Soo Wincci / Wincci 蘇盈之: a distinctive Latin word is a part too.
                for word in credit[range].split(separator: " ").map({ normalized(String($0)) })
                where word.count >= 5 && !genericArtistWords.contains(word) { parts.insert(word) }
                cursor = range.upperBound
            }
            let whole = normalized(credit)
            if !whole.isEmpty, !isShort(whole) { parts.insert(whole) }
        }
        if parts.isEmpty, !normalized(text).isEmpty { parts.insert(normalized(text)) }   // short names such as "en"
        return parts
    }

    private static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        return a.count == b.count && zip(a, b).filter { $0 != $1 }.count <= 1
    }

    /// 情歌變的不好聽 / 情歌變得不好聽: one character may differ in titles of 4+ characters.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        a == b || (a.count >= 4 && oneEdit(a, b))
    }

    /// Shared part, or 柯有綸 / 柯有倫: one character may differ in CJK names of 3+ characters.
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let left = artistParts(a), right = artistParts(b)
        if !left.isDisjoint(with: right) { return true }
        let cjk: (Set<String>) -> [String] = { $0.filter { $0.range(of: #"^\p{Han}{3,}$"#, options: .regularExpression) != nil } }
        return cjk(left).contains { l in cjk(right).contains { oneEdit(l, $0) } }
    }

    /// Covers, live takes and alternate versions, unless the video title says so too.
    static let versionWords = #"(?i)cover|翻唱|伴奏|instrumental|karaoke|remix|(?<![a-z])dj(?![a-z])|live|现场|現場|a\s*cap+ella|版|demo|acoustic|女声|男声|女聲|男聲|合唱|first\s*take"#

    struct Record {
        let title: String
        let artist: String
        let duration: Double?
    }

    /// Whether `record` is this song (not a cover, live take or other version).
    static func isSameSong(_ record: Record, guess: Guess, videoTitle: String, videoDuration: Int?,
                           titleHasArtist: Bool) -> Bool {
        let wanted = bareTitle(guess.song)
        guard !wanted.isEmpty, titlesMatch(bareTitle(record.title), wanted) else { return false }
        if matches(versionWords, record.title + " " + record.artist), !matches(versionWords, videoTitle) { return false }
        if !guess.artist.isEmpty { return artistsMatch(record.artist, guess.artist) }
        // No artist in the title: only a same-length recording identifies the song.
        guard !titleHasArtist, let videoDuration, let duration = record.duration else { return false }
        return abs(duration - Double(videoDuration)) <= 3
    }

    /// The record for this song, preferring the closest length; nil if none is the same song.
    static func bestMatch(_ records: [Record], guess: Guess, videoTitle: String, videoDuration: Int?,
                          titleHasArtist: Bool) -> Record? {
        let candidates = records.filter {
            isSameSong($0, guess: guess, videoTitle: videoTitle, videoDuration: videoDuration, titleHasArtist: titleHasArtist)
        }
        guard let videoDuration else { return candidates.first }
        return candidates.min { lhs, rhs in
            abs((lhs.duration ?? .infinity) - Double(videoDuration)) < abs((rhs.duration ?? .infinity) - Double(videoDuration))
        }
    }

    /// Guess × song-variant queries in order, at most `limit`.
    static func queries(_ title: String, limit: Int = 3) -> [Guess] {
        var result: [Guess] = []
        for guess in guesses(title) {
            for song in songVariants(guess.song) {
                let query = Guess(artist: guess.artist, song: song)
                if !result.contains(query) { result.append(query) }
            }
        }
        return Array(result.prefix(limit))
    }
}
