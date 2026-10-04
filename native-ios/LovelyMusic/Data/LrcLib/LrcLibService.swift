import Foundation

final class LrcLibService: LyricsRepositoryProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(session: URLSession = .shared) {
        self.session = session
        guard let url = URL(string: "https://lrclib.net/api") else {
            fatalError("Invalid hardcoded LrcLib base URL")
        }
        self.baseURL = url
    }

    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await getLyrics(title: title, artist: artist, duration: duration, allowVideoCredits: false)
    }

    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("get"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        let validDuration = duration.flatMap { (1...3600).contains($0) ? $0 : nil }
        if let duration = validDuration {
            queryItems.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("EvanTube/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var (data, httpResponse) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib")
        if httpResponse.statusCode == 404, validDuration != nil {
            components.queryItems = queryItems.filter { $0.name != "duration" }
            request.url = components.url
            (data, httpResponse) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib")
        }
        var relaxedPair: LyricsLookupMetadata.Pair?
        if httpResponse.statusCode == 404,
           let pair = LyricsLookupMetadata.cleaned(title: title, artist: artist, allowVideoCredits: allowVideoCredits) {
            components.queryItems = [URLQueryItem(name: "track_name", value: pair.title),
                                     URLQueryItem(name: "artist_name", value: pair.artist)]
            request.url = components.url
            (data, httpResponse) = try await PublicSourceRequest.data(for: request, session: session, source: "LRCLib")
            relaxedPair = pair
        }
        if httpResponse.statusCode == 404 { return nil }
        guard httpResponse.statusCode == 200 else { throw PublicSourceError.http("LRCLib", httpResponse.statusCode) }

        let lrcResponse = try decoder.decode(LrcLibResponse.self, from: data)
        if let pair = relaxedPair {
            guard let track = lrcResponse.trackName, let performer = lrcResponse.artistName,
                  LyricsLookupMetadata.normalized(track) == LyricsLookupMetadata.normalized(pair.title),
                  LyricsLookupMetadata.normalized(performer) == LyricsLookupMetadata.normalized(pair.artist) else { return nil }
        }

        if let syncedLyrics = lrcResponse.syncedLyrics, !syncedLyrics.isEmpty {
            let lines = parseLRC(syncedLyrics)
            return SyncedLyrics(lines: lines, source: "LrcLib")
        }

        if let plainLyrics = lrcResponse.plainLyrics, !plainLyrics.isEmpty {
            let lines = plainLyrics.components(separatedBy: .newlines)
                .enumerated()
                .map { LyricLine(time: Double($0.offset) * 3.0, text: $0.element) }
            return SyncedLyrics(lines: lines, source: "LrcLib (plain)")
        }

        return nil
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        lrc.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]") else { return nil }

            let timeStr = String(line[line.index(after: line.startIndex)..<closeBracket])
            let text = String(line[line.index(after: closeBracket)...])
                .trimmingCharacters(in: .whitespaces)

            guard !text.isEmpty else { return nil }

            let timeParts = timeStr.split(separator: ":")
            guard timeParts.count == 2,
                  let minutes = Double(timeParts[0]),
                  let seconds = Double(timeParts[1]) else { return nil }

            let time = minutes * 60.0 + seconds
            return LyricLine(time: time, text: text)
        }
    }
}

private struct LrcLibResponse: Codable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let trackName: String?
    let artistName: String?
    let duration: Double?
}
