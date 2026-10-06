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
    struct TransportEvidence: Sendable {
        let attempt: Int
        let httpStatus: Int?
        let fetchSource: String
        let transportErrorCode: Int?
        let latencyMilliseconds: Int
    }
    static func data(for request: URLRequest, session: URLSession = .shared,
                     source: String, retryTransient: Bool = true, diagnostics: ((TransportEvidence) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let started = Date()
            let metrics = diagnostics == nil ? nil : PublicSourceMetrics()
            do {
                let data: Data
                let response: URLResponse
                if let metrics {
                    (data, response) = try await session.data(for: request, delegate: metrics)
                } else {
                    (data, response) = try await session.data(for: request)
                }
                diagnostics?(.init(attempt: attempt + 1, httpStatus: (response as? HTTPURLResponse)?.statusCode,
                    fetchSource: metrics?.fetchSource ?? "not-observed", transportErrorCode: nil,
                    latencyMilliseconds: Int(max(0, Date().timeIntervalSince(started) * 1000))))
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
                diagnostics?(.init(attempt: attempt + 1, httpStatus: nil,
                    fetchSource: metrics?.fetchSource ?? "not-observed", transportErrorCode: error.code.rawValue,
                    latencyMilliseconds: Int(max(0, Date().timeIntervalSince(started) * 1000))))
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

/// Metrics may arrive after the awaited response; absent evidence remains not-observed.
private final class PublicSourceMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sources: Set<String> = []
    var fetchSource: String {
        lock.withLock { sources.isEmpty ? "not-observed" : sources.count == 1 ? sources.first! : "mixed" }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            for transaction in metrics.transactionMetrics {
                switch transaction.resourceFetchType {
                case .networkLoad: sources.insert("network")
                case .localCache: sources.insert("local-cache")
                case .serverPush: sources.insert("server-push")
                case .unknown: sources.insert("not-observed")
                @unknown default: sources.insert("not-observed")
                }
            }
        }
    }
}
