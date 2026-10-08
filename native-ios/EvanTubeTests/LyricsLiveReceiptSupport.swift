import Foundation
import XCTest
@testable import LovelyMusic

/// Used by both the authorized sample and offline native mocks. Mock mode installs
/// an upstream URLProtocol before any request; it cannot fall through to a network.
final class AuthorizedSampleHTTPTransport: URLProtocol {
    private static let lock = NSLock()
    private static var evidence: [[String: Any]] = [], counts: [String: Int] = [:]
    private static var mockProtocol: AnyClass?
    private let taskLock = NSLock()
    private var forwarding: Task<Void, Never>?
    static func configureMock(_ type: AnyClass?) { lock.withLock { mockProtocol = type; evidence = []; counts = [:] } }
    static func beginSample(_ index: Int) { lock.withLock { evidence = []; counts = [:] } }
    static var requests: [[String: Any]] { lock.withLock { evidence } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              request.httpMethod == "GET", request.httpBody == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let primary = components.host == "lrclib.net"
        let provider = primary ? "lrclib" : "lrcapi"
        let route = primary ? ["/api/get", "/api/search"].contains(components.path)
            : components.host == "api.lrc.cx" && components.path == "/jsonapi"
        let allowed: Set<String> = primary ? ["track_name", "artist_name"] : ["title", "artist"]
        let items = components.queryItems ?? []
        guard route, !items.isEmpty, items.allSatisfy({ allowed.contains($0.name) }),
              let queryID = URLProtocol.property(forKey: LyricsQueryObservation.queryIDProperty, in: request) as? String,
              let logicalAttempt = URLProtocol.property(forKey: LyricsQueryObservation.attemptProperty, in: request) as? Int else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let number = Self.lock.withLock { Self.counts[provider, default: 0] += 1; return Self.counts[provider]! }
        guard number <= 12 else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let mock = Self.lock.withLock { Self.mockProtocol }
        let task = Task { [self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
            if let mock { configuration.protocolClasses = [mock] }
            let upstream = URLSession(configuration: configuration, delegate: AuthorizedSampleNoRedirect(), delegateQueue: nil)
            defer { upstream.invalidateAndCancel() }
            let throttleStart = ProcessInfo.processInfo.systemUptime * 1000
            var throttleEnd: Double?
            var networkStart: Double?
            var networkEnd: Double?
            func record(_ response: URLResponse?, error: Error? = nil) {
                let end = ProcessInfo.processInfo.systemUptime * 1000
                let row: [String: Any] = ["provider": provider, "queryID": queryID, "attempt": logicalAttempt,
                    "requestNumber": number, "onlyTitleAndArtist": true, "payloadKeys": items.map(\.name).sorted(),
                    "endpoint": components.path, "httpStatus": (response as? HTTPURLResponse)?.statusCode as Any? ?? NSNull(),
                    "transportErrorCode": error.map { ($0 as NSError).code } as Any? ?? NSNull(),
                    "cancelled": error is CancellationError || (error as? URLError)?.code == .cancelled,
                    "scheduledThrottleMilliseconds": 500, "throttleMilliseconds": max(0, (throttleEnd ?? end) - throttleStart),
                    "networkStartMonotonicMilliseconds": networkStart as Any? ?? NSNull(),
                    "upstreamMilliseconds": networkStart.map { max(0, (networkEnd ?? end) - $0) } ?? 0,
                    "transportMode": mock == nil ? "live" : "mock"]
                Self.lock.withLock { Self.evidence.append(row) }
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
                throttleEnd = ProcessInfo.processInfo.systemUptime * 1000
                var forwarded = request; forwarded.httpShouldHandleCookies = false
                networkStart = ProcessInfo.processInfo.systemUptime * 1000
                let data: Data, response: URLResponse
                do {
                    (data, response) = try await upstream.data(for: forwarded)
                    networkEnd = ProcessInfo.processInfo.systemUptime * 1000
                } catch { networkEnd = ProcessInfo.processInfo.systemUptime * 1000; throw error }
                try Task.checkCancellation()
                record(response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch {
                record(nil, error: error)
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        taskLock.withLock { forwarding = task }
    }
    override func stopLoading() { taskLock.withLock { forwarding?.cancel() } }
}

private final class AuthorizedSampleNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LyricsLiveReceiptBuilder {
    enum ReceiptError: Error { case missingProviderReceipt, missingPhase, missingSelectedEvidence }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    static func row(_ report: LyricsLookupReport, sample: [String: Any], batch: Int,
                    wallMilliseconds: Double, phases: [[String: Any]]) throws -> [String: Any] {
        guard report.queryReceipts.count == 2 else { throw ReceiptError.missingProviderReceipt }
        let expected = report.queryReceipts.flatMap(\.queries).flatMap { query in query.attempts.map { query.queryID + "|" + String($0.attempt) } }.sorted()
        let observed = phases.map { ($0["queryID"] as? String ?? "missing") + "|" + String($0["attempt"] as? Int ?? -1) }.sorted()
        guard expected == observed && Set(observed).count == observed.count else { throw ReceiptError.missingPhase }
        var queries: [[String: Any]] = []
        for provider in report.queryReceipts {
            for query in provider.queries {
                var entry = try object(query)
                entry["attempts"] = try query.attempts.map { attempt -> [String: Any] in
                    guard let phase = phases.first(where: { $0["queryID"] as? String == query.queryID && $0["attempt"] as? Int == attempt.attempt }) else { throw ReceiptError.missingPhase }
                    var item = try object(attempt)
                    for key in ["scheduledThrottleMilliseconds", "throttleMilliseconds", "networkStartMonotonicMilliseconds", "upstreamMilliseconds"] { item[key] = phase[key] }
                    item["httpStatus"] = attempt.httpStatus as Any? ?? NSNull()
                    item["transportErrorCode"] = attempt.transportErrorCode as Any? ?? NSNull()
                    let throttle = phase["throttleMilliseconds"] as? Double ?? 0
                    let upstream = phase["upstreamMilliseconds"] as? Double ?? 0
                    item["localOverheadMilliseconds"] = max(0, attempt.attemptWallMilliseconds - throttle - upstream)
                    return item
                }
                queries.append(entry)
            }
        }
        let receipts = report.queryReceipts
        let providerCoverage = try receipts.map { receipt -> [String: Any] in
            var value = try object(receipt); value.removeValue(forKey: "queries"); return value
        }
        var selected: Any = NSNull()
        if let id = report.lyrics?.selectedRecordID, let candidate = report.lyrics?.candidates.first(where: { $0.id == id }) {
            let content = LyricsContentReceipt(candidate)
            guard let query = receipts.flatMap(\.queries).first(where: { $0.contents.contains { $0.qualifiedRecordID == content.qualifiedRecordID && $0.contentSHA256 == content.contentSHA256 && $0.timelineSHA256 == content.timelineSHA256 } }) else { throw ReceiptError.missingSelectedEvidence }
            var value = try object(content)
            value["evidenceQueryID"] = query.queryID
            value["identityDecision"] = candidate.identityDecision?.kind.rawValue ?? "unknown"
            value["finalScore"] = candidate.identityDecision?.score ?? 0
            value["scoreBreakdown"] = candidate.identityDecision?.scoreBreakdown ?? [:]
            value["confirmedDirectionHypothesisID"] = candidate.identityDecision?.hypothesisID.map(LyricsReceiptDigest.text) as Any? ?? NSNull()
            value["selectionEvaluation"] = "finalComposite"
            value["selectionMargin"] = report.lyrics?.selectionMargin as Any? ?? NSNull()
            value["selectionMethod"] = report.lyrics?.selectionMethod as Any? ?? NSNull()
            selected = value
        }
        let outcome: String
        switch report.state {
        case .synchronized: outcome = "automaticTimed"
        case .confirmedPlain: outcome = "automaticPlain"
        case .manualSelection: outcome = "manualCandidate"
        case .candidatesRejected: outcome = "rejectedCandidates"
        case .providerEmpty: outcome = "emptyProviderResults"
        case .sourceUnavailable: outcome = "sourceUnavailable"
        case .metadataRejected: outcome = "metadataRejected"
        }
        let original = sample.filter { ["title", "artist", "duration", "stratum", "sampleKey"].contains($0.key) }
        return ["batch": batch, "sampleKey": sample["sampleKey"] ?? "missing", "sourceSampleSHA256": LyricsReceiptDigest.json(original),
            "outcome": outcome, "state": report.state.rawValue, "lookupWallMilliseconds": wallMilliseconds,
            "queryLedger": queries, "directionCoverage": ["requiredPairKeys": receipts[0].requiredPairKeys,
                "requiredForAutomatic": receipts[0].requiredForAutomatic, "providers": providerCoverage],
            "selected": selected, "contentRetrieved": receipts.flatMap(\.queries).contains { !$0.contents.isEmpty },
            "sourceAvailabilityFailures": report.failures.map { ["provider": $0.providerID.rawValue, "reason": $0.reason.rawValue, "httpStatus": $0.httpStatus as Any? ?? NSNull()] },
            "humanRecordingIdentity": "NOT_RUN", "humanVocalAlignment": "NOT_RUN"]
    }
    static func context() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: AuthorizedRandomLyricsSampleTests.self).url(forResource: "lyrics_receipt_run_context", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
