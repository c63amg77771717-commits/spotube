import Foundation

struct PlaybackSourceCandidate: Identifiable {
    enum Match: Int {
        case differentVersion = 0
        case needsReview = 1
        case sameIdentity = 2

        var label: String {
            switch self {
            case .sameIdentity: return "歌名、歌手吻合，請確認來源"
            case .needsReview: return "匹配未確認，請核對歌手與版本"
            case .differentVersion: return "可能是翻唱、現場或其他版本"
            }
        }
    }
    let song: Song
    let match: Match
    var id: String { song.id }
}

enum PlaybackSourceReplacementPolicy {
    static func query(for song: Song) -> String {
        [song.artistName, song.title].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func isVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    static func candidates(_ songs: [Song], for original: Song, excluding: Set<String>) -> [PlaybackSourceCandidate] {
        var seen = excluding
        return songs.enumerated().compactMap { index, song -> (Int, PlaybackSourceCandidate)? in
            guard isVideoID(song.id), seen.insert(song.id).inserted else { return nil }
            let title = normalized(song.title)
            let originalTitle = normalized(original.title)
            let artist = normalized(song.artistName)
            let originalArtist = normalized(original.artistName)
            let variants = ["cover", "live", "remix", "karaoke", "instrumental", "slowed", "sped up",
                            "翻唱", "現場", "现场", "混音", "伴奏", "純音樂", "纯音乐"]
            func mentions(_ text: String, _ variant: String) -> Bool {
                if variant.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: variant) + "\\b"
                    return text.range(of: pattern, options: .regularExpression) != nil
                }
                return text.contains(variant)
            }
            let variant = variants.contains { mentions(title, $0) && !mentions(originalTitle, $0) }
            let durationMatches: Bool
            if let expected = original.duration, expected > 0, let actual = song.duration, actual > 0 {
                durationMatches = abs(expected - actual) <= max(8, expected / 10)
            } else { durationMatches = true }
            let exact = !originalTitle.isEmpty && title == originalTitle && !originalArtist.isEmpty
                && artist == originalArtist && song.artistNameSource == .artistMetadata && durationMatches
            let match: PlaybackSourceCandidate.Match = variant ? .differentVersion : (exact ? .sameIdentity : .needsReview)
            return (index, PlaybackSourceCandidate(song: song, match: match))
        }.sorted {
            $0.1.match.rawValue == $1.1.match.rawValue ? $0.0 < $1.0 : $0.1.match.rawValue > $1.1.match.rawValue
        }.map { $0.1 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
