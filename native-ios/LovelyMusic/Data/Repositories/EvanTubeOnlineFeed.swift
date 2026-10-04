import Foundation

struct EvanTubeOnlineItem: Identifiable, Codable {
    enum Kind: String, Codable { case song, release }
    let id: String
    let title: String
    let artist: String
    let artworkURL: String?
    let kind: Kind
    let releaseDate: Date?
}

struct EvanTubeOnlineFeed: Codable {
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
        if structuredTitleMatches(candidate, item: item) { return true }
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
        if presentationStripped(title, matching: expected) == expected { return true }
        return structuredTitleMatches(candidate, item: item)
    }

    private static func presentationStripped(_ value: String, matching expected: String? = nil) -> String {
        var text = value
        let label = "(?:official music video|official lyric video|official video|official audio|music video|lyric video|lyrics|visualizer|official|audio|mv|hd|4k)"
        while let range = text.range(of: "(?:^| )" + label + "$", options: .regularExpression) {
            text.removeSubrange(range)
            if let expected, text == expected { return text }
        }
        return text
    }

    private static func structuredTitleMatches(_ candidate: String, item: EvanTubeOnlineItem) -> Bool {
        // Preserve title delimiters: flattening the bilingual artist and song into one
        // string loses the boundary in e.g. Artist English Name《Song English Title》.
        guard let opening = candidate.range(of: "[《〈]", options: .regularExpression) else { return false }
        let closingCharacter = candidate[opening] == "《" ? "》" : "〉"
        guard let closing = candidate.range(of: closingCharacter, range: opening.upperBound..<candidate.endIndex) else { return false }
        let artist = normalized(item.artist)
        let rawCredit = String(candidate[..<opening.lowerBound])
        let credit = normalized(rawCredit)
        guard !artist.isEmpty else { return false }
        let variants = "\\b(live|cover|remix|mix|acoustic|instrumental|karaoke|unplugged|performance|reaction|review|teaser|trailer|snippet|sped|slowed|nightcore|remaster|remastered|version|piano|guitar|solo|orchestra|orchestral|arrangement|arranged|radio|edit|edition|alternate|alternative|extended|demo|feat|featuring|ft|with|by)\\b"
        func latinMetadata(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy {
                $0.value == 32 || (48...57).contains($0.value) || (97...122).contains($0.value)
            } && value.unicodeScalars.contains { (97...122).contains($0.value) }
                && value.range(of: variants, options: .regularExpression) == nil
        }
        if credit != artist {
            // An alias must cross scripts. Keep guest delimiters before punctuation
            // normalization so a different collaboration cannot become an alias.
            guard artist.unicodeScalars.contains(where: { $0.value > 127 }),
                  !rawCredit.contains(where: { "&＆+＋×/／、,，".contains($0) }),
                  credit.hasPrefix(artist + " "), latinMetadata(String(credit.dropFirst(artist.count + 1))) else { return false }
        }
        let tail = normalized(String(candidate[closing.upperBound...]))
        guard presentationStripped(tail).isEmpty else { return false }
        let title = normalized(String(candidate[opening.upperBound..<closing.lowerBound]))
        let expected = normalized(item.title)
        if title == expected { return true }
        // A separate Latin translation may follow the complete non-Latin catalog
        // title. Never trim more native-language title words or recording variants.
        let nativeTitle = expected.unicodeScalars.contains { $0.value > 127 }
            && !expected.unicodeScalars.contains { (97...122).contains($0.value) }
        guard nativeTitle, !expected.isEmpty, title.hasPrefix(expected + " ") else { return false }
        return latinMetadata(String(title.dropFirst(expected.count + 1)))
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
    private struct CachedChart: Codable {
        let fetchedAt: Date
        let feed: EvanTubeOnlineFeed
    }

    static func chart(region: String, session: URLSession = .shared,
                      defaults: UserDefaults = .standard, now: Date = Date()) async throws -> EvanTubeOnlineFeed {
        guard region.count == 2, region.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw URLError(.badURL)
        }
        let key = "evantube.chart.v1.\(region)"
        do {
            let feed: EvanTubeOnlineFeed
            do { feed = try await appleChart(region: region, session: session) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .badServerResponse { throw error }
            catch {
                if let error = error as? URLError, error.code == .cancelled { throw error }
                feed = try await iTunesChart(region: region, session: session)
            }
            try Task.checkCancellation()
            if let data = try? JSONEncoder().encode(CachedChart(fetchedAt: now, feed: feed)) {
                defaults.set(data, forKey: key)
            }
            return feed
        } catch {
            try Task.checkCancellation()
            if let error = error as? URLError, error.code == .cancelled { throw error }
            if let data = defaults.data(forKey: key),
               let cached = try? JSONDecoder().decode(CachedChart.self, from: data),
               (0...86400).contains(now.timeIntervalSince(cached.fetchedAt)) {
                let date = DateFormatter()
                date.locale = Locale(identifier: "zh_TW")
                date.dateFormat = "yyyy/MM/dd HH:mm"
                return EvanTubeOnlineFeed(sourceName: "\(cached.feed.sourceName) · 快取（取得於 \(date.string(from: cached.fetchedAt))）",
                    updatedAt: cached.feed.updatedAt, periodStart: cached.feed.periodStart, items: cached.feed.items)
            }
            throw error
        }
    }

    private static func appleChart(region: String, session: URLSession) async throws -> EvanTubeOnlineFeed {
        let root = try await json("https://rss.marketingtools.apple.com/api/v2/\(region.lowercased())/music/most-played/20/songs.json", session: session, source: "Apple Music")
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

    private static func iTunesChart(region: String, session: URLSession) async throws -> EvanTubeOnlineFeed {
        let root = try await json("https://itunes.apple.com/\(region.lowercased())/rss/topsongs/limit=20/json", session: session, source: "iTunes")
        guard let feed = root["feed"] as? [String: Any],
              let rows = feed["entry"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        let items = rows.compactMap { row -> EvanTubeOnlineItem? in
            guard let identity = row["id"] as? [String: Any],
                  let attributes = identity["attributes"] as? [String: Any],
                  let id = string(attributes["im:id"]),
                  let title = string((row["im:name"] as? [String: Any])?["label"]) else { return nil }
            return EvanTubeOnlineItem(id: id, title: title,
                artist: string((row["im:artist"] as? [String: Any])?["label"]) ?? "",
                artworkURL: (row["im:image"] as? [[String: Any]])?.last.flatMap { string($0["label"]) },
                kind: .song, releaseDate: nil)
        }
        return EvanTubeOnlineFeed(sourceName: "iTunes · \(region) 熱門歌曲（Apple Music 暫時不可用）",
            updatedAt: date((feed["updated"] as? [String: Any])?["label"]), periodStart: nil, items: items)
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

    private static func json(_ address: String, session: URLSession = .shared, source: String = "線上來源") async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await PublicSourceRequest.data(for: request, session: session, source: source)
        guard response.statusCode == 200 else { throw PublicSourceError.http(source, response.statusCode) }
        guard data.count <= 2 * 1024 * 1024,
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
        let rss = DateFormatter()
        rss.locale = Locale(identifier: "en_US_POSIX")
        rss.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        if let parsed = rss.date(from: text) { return parsed }
        let simple = DateFormatter()
        simple.locale = Locale(identifier: "en_US_POSIX")
        simple.timeZone = TimeZone(secondsFromGMT: 0)
        simple.dateFormat = "yyyy-MM-dd"
        return simple.date(from: text)
    }
}
