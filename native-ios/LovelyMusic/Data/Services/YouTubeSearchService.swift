import Foundation

final class YouTubeSearchService {
    static let continuationPrefix = "yt-data:"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, key: String) async throws -> SearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .empty }
        return try await request(query: query, pageToken: nil, key: key)
    }

    func continueSearch(token: String, key: String) async throws -> SearchResult {
        guard token.hasPrefix(Self.continuationPrefix),
              let data = Data(base64Encoded: String(token.dropFirst(Self.continuationPrefix.count))),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              !cursor.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cursor.pageToken.isEmpty else {
            throw YouTubeSearchError.invalidContinuation
        }
        return try await request(query: cursor.query, pageToken: cursor.pageToken, key: key)
    }

    private func request(query: String, pageToken: String?, key: String) async throws -> SearchResult {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw YouTubeSearchError.keyMissing }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/youtube/v3/search"
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key),
        ]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        guard let url = components.url else { throw YouTubeSearchError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // URLSession errors can contain the request URL, including its API key.
            throw YouTubeSearchError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw YouTubeSearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw Self.responseError(data: data, status: http.statusCode)
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw YouTubeSearchError.invalidResponse
        }
        var seen = Set<String>()
        let songs = result.items.compactMap { item -> Song? in
            guard let id = item.id.videoId, Self.isVideoID(id),
                  let snippet = item.snippet, seen.insert(id).inserted else { return nil }
            let thumbnail = ["maxres", "standard", "high", "medium", "default"]
                .compactMap { snippet.thumbnails?[$0]?.url }.first
            return Song(
                id: id, title: Self.decodingEntities(snippet.title),
                artistName: Self.decodingEntities(snippet.channelTitle),
                artistId: nil, albumName: nil, albumId: nil, duration: nil,
                thumbnailURL: thumbnail
            )
        }
        let continuation: String?
        if let pageToken = result.nextPageToken, !pageToken.isEmpty {
            let cursor = Cursor(query: query, pageToken: pageToken)
            continuation = Self.continuationPrefix + (try JSONEncoder().encode(cursor)).base64EncodedString()
        } else {
            continuation = nil
        }
        return SearchResult(songs: songs, albums: [], artists: [], playlists: [], continuation: continuation)
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    private static func decodingEntities(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "&(#(?:x|X)[0-9A-Fa-f]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);") else {
            return value
        }
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00A0}"]
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var decoded = value
        for match in matches.reversed() {
            guard let entityRange = Range(match.range(at: 1), in: value),
                  let range = Range(match.range, in: decoded) else { continue }
            let entity = String(value[entityRange])
            let replacement: String?
            if entity.hasPrefix("#") {
                let isHex = entity.lowercased().hasPrefix("#x")
                let number = UInt32(entity.dropFirst(isHex ? 2 : 1), radix: isHex ? 16 : 10)
                replacement = number.flatMap { UnicodeScalar($0) }.map { String($0) }
            } else {
                replacement = named[entity]
            }
            if let replacement { decoded.replaceSubrange(range, with: replacement) }
        }
        return decoded
    }

    private static func responseError(data: Data, status: Int) -> YouTubeSearchError {
        let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
        let reasons = ((error?.errors ?? []) + (error?.details ?? [])).compactMap(\.reason).map { $0.lowercased() }
        if status == 429 || reasons.contains(where: { $0.contains("quota") || $0.contains("limitexceeded") }) {
            return .quotaExceeded
        }
        if reasons.contains(where: { $0 == "accessnotconfigured" || $0 == "servicedisabled" || $0 == "service_disabled" }) {
            return .apiDisabled
        }
        if reasons.contains(where: { $0.contains("key") || $0.contains("referer") })
            || error?.message?.lowercased().contains("api key not valid") == true {
            return .keyRejected
        }
        return status == 401 || status == 403 ? .keyRejected : .requestFailed(status)
    }

    private struct Cursor: Codable {
        let query: String
        let pageToken: String
    }

    private struct Response: Decodable {
        let items: [Item]
        let nextPageToken: String?
    }

    private struct Item: Decodable {
        let id: VideoID
        let snippet: Snippet?
        struct VideoID: Decodable { let videoId: String? }
        struct Snippet: Decodable {
            let title: String
            let channelTitle: String
            let thumbnails: [String: Thumbnail]?
        }
        struct Thumbnail: Decodable { let url: String? }
    }

    private struct ErrorResponse: Decodable {
        let error: APIError
        struct APIError: Decodable {
            let errors: [Reason]?
            let details: [Reason]?
            let message: String?
        }
        struct Reason: Decodable { let reason: String? }
    }
}

enum YouTubeSearchError: LocalizedError {
    case keyMissing
    case keyRejected
    case apiDisabled
    case quotaExceeded
    case unsupportedFilter
    case invalidContinuation
    case invalidResponse
    case networkUnavailable
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .keyMissing: return "尚未設定 YouTube 搜尋 API 金鑰，請到設定加入金鑰。"
        case .keyRejected: return "YouTube 搜尋金鑰無效或受到限制，請檢查金鑰與 iOS App 的使用限制。"
        case .apiDisabled: return "這個金鑰的 Google Cloud 專案尚未啟用 YouTube Data API v3，請啟用後再試。"
        case .quotaExceeded: return "YouTube 搜尋配額已用完或請求過於頻繁，請稍後再試或更換有可用配額的金鑰。"
        case .unsupportedFilter: return "YouTube 官方來源目前只支援歌曲搜尋。"
        case .invalidContinuation: return "搜尋分頁已失效，請重新搜尋。"
        case .invalidResponse: return "YouTube 搜尋回應無法讀取，請稍後再試。"
        case .networkUnavailable: return "無法連線至 YouTube 搜尋，請檢查網路後再試。"
        case .requestFailed(let status): return "YouTube 搜尋失敗（HTTP \(status)），請稍後再試。"
        }
    }
}
