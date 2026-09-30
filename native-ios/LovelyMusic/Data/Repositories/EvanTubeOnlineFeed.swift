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

enum EvanTubeOnlineFeedService {
    static func chart(region: String) async throws -> EvanTubeOnlineFeed {
        guard region.count == 2, region.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw URLError(.badURL)
        }
        let root = try await json("https://rss.applemarketingtools.com/api/v2/\(region.lowercased())/music/most-played/20/songs.json")
        let feed = root["feed"] as? [String: Any] ?? [:]
        let items = (feed["results"] as? [[String: Any]] ?? []).compactMap { row -> EvanTubeOnlineItem? in
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
        let payload = root["payload"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        let items = (payload["recordings"] as? [[String: Any]] ?? []).compactMap { row -> EvanTubeOnlineItem? in
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
        let payload = root["payload"] as? [String: Any] ?? [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        var seen = Set<String>()
        let items = (payload["releases"] as? [[String: Any]] ?? []).compactMap { row -> EvanTubeOnlineItem? in
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
