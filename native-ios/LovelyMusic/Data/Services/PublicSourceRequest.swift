import Foundation

enum PublicSourceError: Error, LocalizedError {
    case http(String, Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let source, let status): return "\(source) 回應 HTTP \(status)"
        case .invalidResponse(let source): return "\(source) 回應格式無法讀取"
        }
    }
}

enum PublicSourceRequest {
    static func data(for request: URLRequest, session: URLSession = .shared,
                     source: String, retryTransient: Bool = true) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PublicSourceError.invalidResponse(source)
                }
                if retryTransient, attempt == 0, let delay = retryDelay(status: http.statusCode,
                                                       retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                guard retryTransient, attempt == 0, [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                     .cannotFindHost, .dnsLookupFailed].contains(error.code) else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw PublicSourceError.invalidResponse(source)
    }

    static func retryDelay(status: Int, retryAfter: String?, now: Date = Date()) -> Double? {
        guard status == 408 || status == 429 || (500...599).contains(status) else { return nil }
        guard let retryAfter else { return 0.25 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let delay = Double(retryAfter) ?? formatter.date(from: retryAfter).map({ $0.timeIntervalSince(now) }),
              delay <= 5 else { return nil }
        return max(0, delay)
    }
}
