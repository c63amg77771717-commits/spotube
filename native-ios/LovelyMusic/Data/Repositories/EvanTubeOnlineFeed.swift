import Foundation

struct EvanTubeOnlineItem: Identifiable {
    enum Kind { case song, release }
    let id: String
    let title: String
    let artist: String
    let artworkURL: String?
    let kind: Kind
    let releaseDate: Date?
}

struct EvanTubeOnlineFeed {
    let sourceName: String
    let updatedAt: Date?
    let periodStart: Date?
    let items: [EvanTubeOnlineItem]
}

enum EvanTubeOnlineSongResolver {
    static func isPlayable(_ song: Song) -> Bool {
        !song.isEpisode && song.hasYouTubeOrigin && song.id.utf8.allSatisfy { $0 < 128 }
    }

    static func resolve(_ item: EvanTubeOnlineItem,
                        search: (String) async throws -> [Song]) async throws -> Song? {
        guard item.kind == .song, !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try Task.checkCancellation()
        let query = "\(item.title) \(item.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let results = try await search(query)
        try Task.checkCancellation()
        var seen = Set<String>()
        let candidates = ContentPreferences.filteredSongs(results).filter {
            let channel = $0.artistName.replacingOccurrences(of: "(?i)vevo$", with: "", options: .regularExpression)
            return isPlayable($0) && titleMatches($0.title, item: item)
                && (item.artist.isEmpty || matches(channel, item.artist) || hasArtistCredit($0.title, item: item))
                && seen.insert($0.id).inserted
        }
        // Search order does not prove which recording the listener intended.
        guard candidates.count == 1, let song = candidates.first else { return nil }
        // Keep the catalog artist for future taste seeds; an uploader may be a record label.
        return Song(id: song.id, title: item.title,
                    artistName: item.artist.isEmpty ? song.artistName : item.artist,
                    artistId: song.artistId, albumName: song.albumName, albumId: song.albumId,
                    duration: song.duration, thumbnailURL: song.thumbnailURL ?? item.artworkURL,
                    isExplicit: song.isExplicit, musicVideoType: song.musicVideoType,
                    isEpisode: song.isEpisode, episodeOf: song.episodeOf,
                    streamURL: song.streamURL, streamContentLength: song.streamContentLength)
    }

    private static func normalized(_ value: String) -> String {
        let text = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                            locale: Locale(identifier: "zh_TW"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hasArtistCredit(_ candidate: String, item: EvanTubeOnlineItem) -> Bool {
        let title = normalized(candidate)
        let artistPattern = normalized(item.artist).split(separator: " ").map {
            NSRegularExpression.escapedPattern(for: String($0))
        }.joined(separator: " ?")
        guard !artistPattern.isEmpty,
              let prefix = title.range(of: "^" + artistPattern + " ", options: .regularExpression) else { return false }
        // A title word is not performer evidence: the remaining text must still name the complete recording.
        return titleMatches(String(title[prefix.upperBound...]), item: item, stripArtistPrefix: false)
    }

    private static func titleMatches(_ candidate: String, item: EvanTubeOnlineItem, stripArtistPrefix: Bool = true) -> Bool {
        func creditNormalized(_ text: String) -> String {
            normalized(text).replacingOccurrences(of: "\\b(featuring|feat|ft)\\b", with: "feat", options: .regularExpression)
        }
        var title = creditNormalized(candidate)
        let expected = creditNormalized(item.title)
        if title == expected { return true }
        let artist = normalized(item.artist)
        let artistPattern = artist.split(separator: " ").map {
            NSRegularExpression.escapedPattern(for: String($0))
        }.joined(separator: " ?")
        // Artist-prefixed official metadata is common even when the uploader is a label.
        if stripArtistPrefix, !artist.isEmpty, let prefix = title.range(of: "^" + artistPattern + " ", options: .regularExpression) {
            title = String(title[prefix.upperBound...])
        }
        if title == expected { return true }
        // Only remove known presentation labels, never arbitrary remaining title words.
        let suffix = "(?:official music video|official lyric video|official video|official audio|music video|lyric video|lyrics|visualizer|official|audio|mv|hd|4k)"
        while let range = title.range(of: "(?:^| )" + suffix + "$", options: .regularExpression) {
            title.removeSubrange(range)
            if title == expected { return true }
        }
        return false
    }

    fileprivate static func matches(_ candidate: String, _ expected: String) -> Bool {
        let lhs = normalized(candidate), rhs = normalized(expected)
        guard !rhs.isEmpty else { return false }
        let words = rhs.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![a-z0-9])" + words.joined(separator: " ?") + "(?![a-z0-9])"
        return lhs.range(of: pattern, options: .regularExpression) != nil
    }
}

enum EvanTubeOnlineAlbumResolver {
    static func resolve(_ item: EvanTubeOnlineItem, searchUseCase: SearchMusicUseCase) async throws -> Album? {
        guard item.kind == .release else { return nil }
        let query = "\(item.title) \(item.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        // Official video search cannot return Music albums; keep the album-capable repository route.
        let result = try await searchUseCase.execute(query: query, filter: .albums)
        return result.albums.first { EvanTubeOnlineSongResolver.matches($0.title, item.title) }
    }
}

enum EvanTubeOnlineFeedService {
    static func chart(region: String) async throws -> EvanTubeOnlineFeed {
        guard region.count == 2, region.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw URLError(.badURL)
        }
        let root = try await json("https://rss.applemarketingtools.com/api/v2/\(region.lowercased())/music/most-played/20/songs.json")
        guard let feed = root["feed"] as? [String: Any],
              let rows = feed["results"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        let items = rows.compactMap { row -> EvanTubeOnlineItem? in
            guard let id = string(row["id"]), let title = string(row["name"]) else { return nil }
            return EvanTubeOnlineItem(
                id: id, title: title, artist: string(row["artistName"]) ?? "",
                artworkURL: string(row["artworkUrl100"]), kind: .song, releaseDate: nil
            )
        }
        return EvanTubeOnlineFeed(
            sourceName: "Apple Music · \(region)",
            updatedAt: date(feed["updated"]), periodStart: nil, items: items
        )
    }

    static func weekly() async throws -> EvanTubeOnlineFeed {
        let root = try await json("https://api.listenbrainz.org/1/stats/sitewide/recordings?range=week&count=20")
        guard let payload = root["payload"] as? [String: Any],
              let rows = payload["recordings"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        var seen = Set<String>()
        let items = rows.compactMap { row -> EvanTubeOnlineItem? in
            guard let id = string(row["recording_mbid"]),
                  let title = string(row["track_name"]), seen.insert(id).inserted else { return nil }
            return EvanTubeOnlineItem(
                id: id, title: title, artist: string(row["artist_name"]) ?? "",
                artworkURL: nil, kind: .song, releaseDate: nil
            )
        }
        return EvanTubeOnlineFeed(
            sourceName: "ListenBrainz · 社群週榜",
            updatedAt: date(payload["last_updated"]),
            periodStart: date(payload["from_ts"]), items: items
        )
    }

    static func releases(now: Date = Date()) async throws -> EvanTubeOnlineFeed {
        let root = try await json("https://api.listenbrainz.org/1/explore/fresh-releases?days=7&future=false")
        guard let payload = root["payload"] as? [String: Any],
              let rows = payload["releases"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        var seen = Set<String>()
        let items = rows.compactMap { row -> EvanTubeOnlineItem? in
            guard let id = string(row["release_mbid"]),
                  let title = string(row["release_name"]),
                  let releaseDate = date(row["release_date"]),
                  releaseDate <= today,
                  seen.insert(id).inserted else { return nil }
            let coverID = string(row["caa_id"])
            let coverRelease = string(row["caa_release_mbid"]) ?? id
            let artwork = coverID.map { "https://archive.org/download/mbid-\(coverRelease)/\($0)-250.jpg" }
            return EvanTubeOnlineItem(
                id: id, title: title, artist: string(row["artist_credit_name"]) ?? "",
                artworkURL: artwork, kind: .release, releaseDate: releaseDate
            )
        }.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        return EvanTubeOnlineFeed(
            sourceName: "ListenBrainz · MusicBrainz",
            updatedAt: date(payload["last_updated"]), periodStart: nil, items: items
        )
    }

    private static func json(_ address: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return root
    }

    private static func string(_ raw: Any?) -> String? {
        if let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func date(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let parsed = iso.date(from: text) { return parsed }
        let simple = DateFormatter()
        simple.locale = Locale(identifier: "en_US_POSIX")
        simple.timeZone = TimeZone(secondsFromGMT: 0)
        simple.dateFormat = "yyyy-MM-dd"
        return simple.date(from: text)
    }
}
