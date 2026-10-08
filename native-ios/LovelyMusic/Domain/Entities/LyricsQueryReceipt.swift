import Foundation
import CryptoKit

/// Opt-in, lookup-scoped evidence. No lyric text, metadata strings, headers or
/// user identifiers are serialized. Pair/record/content keys are SHA256 digests.
enum LyricsReceiptDigest {
    static func data(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func text(_ value: String) -> String { data(Data(value.utf8)) }
    static func json(_ value: Any) -> String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return data(bytes)
    }
    static func pair(_ value: LyricsLookupMetadata.Pair) -> String { text(LyricsDirectionCoverage.key(value)) }
    static func record(_ value: LyricsRecordID) -> String { value.providerID.rawValue + ":" + text(value.recordID) }
}

struct LyricsContentReceipt: Codable {
    let qualifiedRecordID: String
    let contentSHA256: String
    let timelineSHA256: String
    let contentLineCount: Int
    let timedLineCount: Int
    let timingQualified: Bool
    init(_ candidate: LyricsCandidate) {
        qualifiedRecordID = LyricsReceiptDigest.record(candidate.id)
        contentSHA256 = LyricsReceiptDigest.json(candidate.lyrics.lines.map(\.text))
        timelineSHA256 = LyricsReceiptDigest.json(candidate.lyrics.lines.map { ["text": $0.text, "time": $0.time.isFinite ? $0.time as Any : NSNull()] as [String: Any] })
        contentLineCount = candidate.lyrics.lines.count
        timedLineCount = candidate.lyrics.lines.filter { $0.time.isFinite && $0.time >= 0 }.count
        timingQualified = candidate.lyrics.isTimeSynced
    }
}

struct LyricsHTTPAttemptReceipt: Codable {
    let attempt: Int
    let httpStatus: Int?
    let transportErrorCode: Int?
    let cancelled: Bool
    let fetchSource: String
    let startMonotonicMilliseconds: Double
    let endMonotonicMilliseconds: Double
    let attemptWallMilliseconds: Double
}

struct LyricsLogicalQueryReceipt: Codable {
    let provider: String
    let lookupID: String
    let queryID: String
    let logicalIndex: Int
    let endpoint: String
    let pairKey: String
    var payloadKeys: [String]
    var outcome = "notAttempted"
    var skipReason: String? = "plannedNotReached"
    var coverageMutation = "none"
    var returnedCount: Int? = nil
    var inspectedCount: Int? = nil
    var metadataComplete: Bool? = nil
    var responseSHA256: String? = nil
    var attempts: [LyricsHTTPAttemptReceipt] = []
    var retryBackoffMilliseconds: Double = 0
    var contents: [LyricsContentReceipt] = []
}

struct LyricsProviderQueryReceipt: Codable {
    let provider: String
    let lookupID: String
    let capturedFrom = "productionAdapter.directionCoverage"
    let requiredForAutomatic: Bool
    let requiredPairKeys: [String]
    let completedPairKeys: [String]
    let missingPairKeys: [String]
    let incomplete: Bool
    let coversRequiredPairs: Bool
    let cancelled: Bool
    let providerWallMilliseconds: Double
    let queries: [LyricsLogicalQueryReceipt]
}

final class LyricsQueryObservation: @unchecked Sendable {
    static let queryIDProperty = "EvanTubeReceiptQueryID"
    static let attemptProperty = "EvanTubeReceiptAttempt"
    private let lock = NSLock()
    private var value: LyricsLogicalQueryReceipt
    init(_ value: LyricsLogicalQueryReceipt) { self.value = value }
    var queryID: String { lock.withLock { value.queryID } }
    var snapshot: LyricsLogicalQueryReceipt { lock.withLock { value } }
    func begin() { lock.withLock { value.outcome = "pending"; value.skipReason = nil } }
    func body(_ data: Data) { lock.withLock { value.responseSHA256 = LyricsReceiptDigest.data(data) } }
    func attempt(_ value: LyricsHTTPAttemptReceipt) { lock.withLock { self.value.attempts.append(value) } }
    func backoff(_ milliseconds: Double) { lock.withLock { value.retryBackoffMilliseconds += milliseconds } }
    func content(_ candidate: LyricsCandidate) { lock.withLock { value.contents.append(.init(candidate)) } }
    func complete(count: Int, metadataComplete: Bool, coverage: String) {
        lock.withLock {
            value.returnedCount = count; value.inspectedCount = min(count, 30)
            value.metadataComplete = metadataComplete; value.coverageMutation = coverage
            value.outcome = count > 30 ? "truncated" : !metadataComplete ? "malformed" : "completed"
        }
    }
    func fail(_ error: Error, coverage: String) {
        lock.withLock {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
            let schema = error is DecodingError || { if let error = error as? PublicSourceError, case .invalidResponse = error { return true }; return false }()
            value.outcome = cancelled ? "cancelled" : schema ? "malformed" : "failed"
            value.coverageMutation = coverage
        }
    }
    func skip(_ reason: String, outcome: String = "notAttempted") {
        lock.withLock { if value.outcome == "notAttempted" { value.outcome = outcome; value.skipReason = reason } }
    }
    func tag(_ request: URLRequest, attempt: Int) -> URLRequest {
        lock.withLock { value.payloadKeys = (request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []).map(\.name).sorted() }
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(queryID, forKey: Self.queryIDProperty, in: mutable)
        URLProtocol.setProperty(attempt, forKey: Self.attemptProperty, in: mutable)
        return mutable as URLRequest
    }
}

final class LyricsQueryRecorder {
    private let provider: LyricsProviderID
    private let lookupID = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime
    private let required: [LyricsLookupMetadata.Pair]
    private let requiresEvidence: Bool
    private var entries: [LyricsQueryObservation] = []
    private var stoppedAfterFailure = false
    init(provider: LyricsProviderID, metadata: LyricsCanonicalMetadata) {
        self.provider = provider
        required = LyricsDirectionPolicy.requiredPairs(metadata)
        requiresEvidence = LyricsDirectionPolicy.requiresEvidence(metadata)
    }
    func plan(_ queries: [(String, LyricsLookupMetadata.Pair, [String])]) -> [LyricsQueryObservation] {
        let planned = queries.map { endpoint, pair, keys in make(endpoint: endpoint, pair: pair, keys: keys) }
        let searched = Set(queries.filter { $0.0 != "/api/get" }.map { LyricsReceiptDigest.pair($0.1) })
        for pair in required where !searched.contains(LyricsReceiptDigest.pair(pair)) {
            let observation = make(endpoint: provider == .lrclib ? "/api/search" : "/jsonapi", pair: pair,
                                   keys: provider == .lrclib ? ["track_name", "artist_name"] : ["title", "artist"])
            observation.skip("sixQueryBudgetOmittedRequiredPair", outcome: "budgetOmitted")
        }
        return planned
    }
    func stopped() { stoppedAfterFailure = true }
    private func make(endpoint: String, pair: LyricsLookupMetadata.Pair, keys: [String]) -> LyricsQueryObservation {
        let index = entries.count
        let value = LyricsQueryObservation(.init(provider: provider.rawValue, lookupID: lookupID,
            queryID: lookupID + "/" + String(index), logicalIndex: index, endpoint: endpoint,
            pairKey: LyricsReceiptDigest.pair(pair), payloadKeys: keys.sorted()))
        entries.append(value)
        return value
    }
    func snapshot(coverage: LyricsDirectionCoverage, cancelled: Bool = false) -> LyricsProviderQueryReceipt {
        for entry in entries {
            entry.skip(cancelled ? "lookupCancelledBeforeQuery" : stoppedAfterFailure ? "providerStoppedAfterFailure" : "lookupReturnedBeforeQuery",
                       outcome: cancelled || stoppedAfterFailure ? "notAttempted" : "earlyReturn")
        }
        let completed = coverage.completedPairs.map(LyricsReceiptDigest.text).sorted()
        return .init(provider: provider.rawValue, lookupID: lookupID, requiredForAutomatic: requiresEvidence,
            requiredPairKeys: required.map(LyricsReceiptDigest.pair), completedPairKeys: completed,
            missingPairKeys: required.map(LyricsReceiptDigest.pair).filter { !completed.contains($0) },
            incomplete: coverage.incomplete, coversRequiredPairs: coverage.covers(required), cancelled: cancelled,
            providerWallMilliseconds: max(0, ProcessInfo.processInfo.systemUptime - started) * 1000,
            queries: entries.map(\.snapshot))
    }
}
