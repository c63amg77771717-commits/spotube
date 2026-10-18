import Foundation

/// Song/channel labels are evidence, not proof of matching recordings. No
/// automatic application and no artist aliases inferred from an uploader.
enum PlaylistSourceIdentityPolicy {
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static let presentations = #"(?i)\s*(?:[\[(【]\s*(?:official\s+(?:music\s+)?(?:audio|video|mv)|music\s+video|官方(?:音樂|音乐)?(?:錄影帶|录影带|mv|音訊|音频))\s*[\])】]|official\s+(?:audio|video))\s*$"#
    private static let versionWords = ["live", "remix", "cover", "acoustic", "instrumental", "karaoke", "slowed", "sped up", "現場", "现场", "翻唱", "混音", "伴奏"]
    static func versions(_ text: String) -> Set<String> {
        let input = normalize(text)
        return Set(versionWords.filter { term in
            if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
                return input.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b",
                                   options: .regularExpression) != nil
            }
            return input.contains(term)
        })
    }
    private static func title(_ song: Song) -> (String, Bool) {
        var value = song.title.replacingOccurrences(of: presentations, with: "", options: .regularExpression)
        var inferred = false
        let parts = value.components(separatedBy: " - ")
        if parts.count == 2,
           normalize(parts[0]) == normalize(song.artistName) || song.artistNameSource != .artistMetadata {
            value = parts[1]; inferred = true
        }
        // A bounded parenthesized version is used only for the same-composition
        // comparison. The version evidence is retained separately and warned.
        let versions = #"(?i)\s*[\[(（]\s*(?:live|remix|cover|acoustic|instrumental|karaoke|slowed|sped up|現場|现场|翻唱|混音|伴奏)\s*[\])）]\s*$"#
        value = value.replacingOccurrences(of: versions, with: "", options: .regularExpression)
        return (normalize(value), inferred)
    }
    static func candidates(_ songs: [Song], original: Song, excluding: Set<String>) -> [PlaybackSourceCandidate] {
        var seen = excluding.union([original.id])
        let originalTitle = title(original)
        return songs.enumerated().compactMap { index, song -> (Int, PlaybackSourceCandidate)? in
            guard PlaybackSourceReplacementPolicy.isVideoID(song.id), seen.insert(song.id).inserted else { return nil }
            let candidateTitle = title(song)
            guard !originalTitle.0.isEmpty, originalTitle.0 == candidateTitle.0 else { return nil }
            let knownOriginal = original.artistNameSource == .artistMetadata && !original.artistName.isEmpty
            let knownCandidate = song.artistNameSource == .artistMetadata && !song.artistName.isEmpty
            if knownOriginal && knownCandidate && normalize(original.artistName) != normalize(song.artistName) { return nil }
            let versionDifference = versions(original.title) != versions(song.title)
            let durationsKnown = (original.duration ?? 0) > 0 && (song.duration ?? 0) > 0
            let durationMatches = durationsKnown && abs((original.duration ?? 0) - (song.duration ?? 0)) <= max(8, Int(Double(original.duration ?? 0) * 0.05))
            let verified = knownOriginal && knownCandidate && durationMatches && !originalTitle.1 && !candidateTitle.1
            let match: PlaybackSourceCandidate.Match = versionDifference ? .differentVersion : verified ? .sameIdentity : .needsReview
            return (index, PlaybackSourceCandidate(song: song, match: match))
        }.sorted { lhs, rhs in
            lhs.1.match.rawValue == rhs.1.match.rawValue ? lhs.0 < rhs.0 : lhs.1.match.rawValue > rhs.1.match.rawValue
        }.map { $0.1 }
    }
}
