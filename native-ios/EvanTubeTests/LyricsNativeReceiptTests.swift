import Foundation
import XCTest
@testable import LovelyMusic

final class LyricsNativeReceiptTests: XCTestCase {
    private var measuredWalls: [String: Double] = [:]
    private let credit = "Performer - Track (Lyrics) ft. Guest"
    private func withSources(_ mode: String, body: (LrcLibService, CompositeLyricsRepository, LyricsLookupContext) async throws -> Void) async throws {
        ReceiptUpstreamMock.configure(mode)
        AuthorizedSampleHTTPTransport.configureMock(ReceiptUpstreamMock.self)
        defer { AuthorizedSampleHTTPTransport.configureMock(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "LyricsReceiptMock." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = LrcLibService(session: session, defaults: defaults, captureReceipts: true)
        let secondary = LrcApiService(session: session, defaults: defaults, captureReceipts: true)
        let composite = CompositeLyricsRepository(primary: primary, secondary: secondary, defaults: defaults,
            secondaryEnabled: { true }, probeBothSources: true)
        try await body(primary, composite, .init(title: credit, artist: "", duration: 200, hasYouTubeOrigin: true))
    }
    private func measuredLookup(_ repository: CompositeLyricsRepository, context: LyricsLookupContext) async throws -> LyricsLookupReport {
        let start = ProcessInfo.processInfo.systemUptime
        let report = try await repository.lookup(context: context)
        if let id = report.queryReceipts.first?.lookupID { measuredWalls[id] = max(0, ProcessInfo.processInfo.systemUptime - start) * 1000 }
        return report
    }
    private func serialized(_ report: LyricsLookupReport) throws -> [String: Any] {
        try LyricsLiveReceiptBuilder.row(report,
            sample: ["title": credit, "artist": "", "duration": 200, "stratum": "latin-title", "sampleKey": "sample-01"],
            batch: 1, wallMilliseconds: try XCTUnwrap(measuredWalls[report.queryReceipts.first?.lookupID ?? ""]), phases: AuthorizedSampleHTTPTransport.requests)
    }

    func testActualBothProvidersAndFinalSelectedContentDigest() async throws {
        try await withSources("complete") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            XCTAssertEqual(report.state, .synchronized)
            XCTAssertEqual(report.queryReceipts.count, 2)
            XCTAssertTrue(report.queryReceipts.allSatisfy(\.coversRequiredPairs))
            let receipt = try serialized(report)
            let selected = try XCTUnwrap(receipt["selected"] as? [String: Any])
            XCTAssertEqual(selected["qualifiedRecordID"] as? String, report.lyrics?.selectedRecordID.map(LyricsReceiptDigest.record))
            XCTAssertGreaterThanOrEqual(selected["finalScore"] as? Int ?? 0, 85)
            XCTAssertEqual(selected["selectionEvaluation"] as? String, "finalComposite")
            XCTAssertEqual(selected["contentLineCount"] as? Int, 2)
            XCTAssertEqual((selected["timelineSHA256"] as? String)?.count, 64)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
            XCTAssertFalse(text.contains("Synthetic private-like line"))
            XCTAssertFalse(text.contains("Performer"))
            XCTAssertFalse(text.contains("Guest"))
            XCTAssertFalse(text.contains("Track"))
            for attempt in (receipt["queryLedger"] as? [[String: Any]] ?? []).flatMap({ $0["attempts"] as? [[String: Any]] ?? [] }) {
                XCTAssertGreaterThanOrEqual(attempt["throttleMilliseconds"] as? Double ?? 0, 450)
                XCTAssertGreaterThan(attempt["upstreamMilliseconds"] as? Double ?? 0, 5)
                XCTAssertGreaterThan(attempt["attemptWallMilliseconds"] as? Double ?? 0, attempt["throttleMilliseconds"] as? Double ?? 0)
            }
        }
    }

    func testActualEmptySearchIsCompleteAbsenceEvidence() async throws {
        try await withSources("empty") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            XCTAssertEqual(report.state, .providerEmpty)
            XCTAssertTrue(report.queryReceipts.allSatisfy(\.coversRequiredPairs))
            XCTAssertTrue(report.queryReceipts.flatMap(\.queries).allSatisfy { $0.returnedCount == 0 && $0.metadataComplete == true && $0.coverageMutation == "recordSuccess" })
            XCTAssertEqual(try serialized(report)["contentRetrieved"] as? Bool, false)
        }
    }

    func testActualTruncationRetainsFullCountAndCannotProveAbsence() async throws {
        try await withSources("truncated") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            XCTAssertEqual(report.state, .manualSelection)
            let second = try XCTUnwrap(report.queryReceipts.first { $0.provider == "lrcapi" })
            XCTAssertFalse(second.coversRequiredPairs)
            XCTAssertTrue(second.incomplete)
            let query = try XCTUnwrap(second.queries.first { $0.outcome == "truncated" })
            XCTAssertEqual(query.returnedCount, 31)
            XCTAssertEqual(query.inspectedCount, 30)
            XCTAssertEqual(query.coverageMutation, "recordIncomplete")
            _ = try serialized(report)
        }
    }

    func testActualMalformedIdentityDoesNotCountAsCompletedPair() async throws {
        try await withSources("metadata") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            XCTAssertEqual(report.state, .manualSelection)
            let second = try XCTUnwrap(report.queryReceipts.first { $0.provider == "lrcapi" })
            let query = try XCTUnwrap(second.queries.first { $0.outcome == "malformed" })
            XCTAssertEqual(query.returnedCount, 1)
            XCTAssertEqual(query.metadataComplete, false)
            XCTAssertEqual(query.coverageMutation, "recordIncomplete")
            XCTAssertFalse(second.completedPairKeys.contains(query.pairKey))
            _ = try serialized(report)
        }
    }

    func testActualDecodeFailureLeavesOtherQueriesExplicitlyUnattempted() async throws {
        try await withSources("decode") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            let second = try XCTUnwrap(report.queryReceipts.first { $0.provider == "lrcapi" })
            let failed = try XCTUnwrap(second.queries.first { $0.outcome == "malformed" })
            XCTAssertNil(failed.returnedCount, "Decode failure must not fabricate an empty result")
            XCTAssertEqual(failed.coverageMutation, "recordFailure")
            XCTAssertEqual(failed.attempts.first?.httpStatus, 200)
            XCTAssertNotNil(failed.responseSHA256)
            XCTAssertTrue(second.queries.contains { $0.outcome == "notAttempted" && $0.skipReason == "providerStoppedAfterFailure" && $0.attempts.isEmpty })
            XCTAssertTrue(second.incomplete)
            _ = try serialized(report)
        }
    }

    func testActualRetrySeparatesThrottleNetworkAndMeasuredBackoff() async throws {
        try await withSources("retry") { _, composite, context in
            let report = try await measuredLookup(composite, context: context)
            XCTAssertEqual(report.state, .synchronized)
            let retried = try XCTUnwrap(report.queryReceipts.flatMap(\.queries).first { $0.attempts.count == 2 })
            XCTAssertEqual(retried.attempts.compactMap(\.httpStatus), [503, 200])
            XCTAssertGreaterThanOrEqual(retried.retryBackoffMilliseconds, 40)
            XCTAssertLessThan(retried.retryBackoffMilliseconds, 1000)
            let serializedQuery = try XCTUnwrap((try serialized(report)["queryLedger"] as? [[String: Any]])?.first { $0["queryID"] as? String == retried.queryID })
            XCTAssertEqual((serializedQuery["attempts"] as? [[String: Any]])?.count, 2)
        }
    }

    func testActualPlannerReportsRequiredPairsOmittedBySixQueryBudget() async throws {
        try await withSources("budget") { primary, _, _ in
            let context = LyricsLookupContext(title: "藝人 Artist - 歌曲 Track【官方繁體中文字幕與完整歌詞示範片段，請勿把演唱者與歌曲名稱交換】", artist: "", duration: 200, hasYouTubeOrigin: true)
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
            XCTAssertGreaterThan(LyricsDirectionPolicy.requiredPairs(metadata).count, LyricsQueryPlanner.queries(metadata).count)
            let report = try await primary.lookup(context: context)
            let receipt = try XCTUnwrap(report.queryReceipts.first)
            XCTAssertLessThanOrEqual(receipt.queries.filter { !$0.attempts.isEmpty }.count, 6)
            XCTAssertTrue(receipt.queries.contains { $0.outcome == "budgetOmitted" && $0.attempts.isEmpty && $0.coverageMutation == "none" })
            XCTAssertFalse(receipt.coversRequiredPairs)
            XCTAssertFalse(receipt.missingPairKeys.isEmpty)
            XCTAssertTrue(report.failures.isEmpty)
        }
    }

    func testCancellationBeforeUpstreamRetainsActualPartialThrottle() async throws { try await cancellation(duringNetwork: false) }
    func testCancellationDuringUpstreamRetainsSeparatePartialNetwork() async throws { try await cancellation(duringNetwork: true) }
    private func cancellation(duringNetwork: Bool) async throws {
        ReceiptUpstreamMock.configure("slow")
        AuthorizedSampleHTTPTransport.configureMock(ReceiptUpstreamMock.self)
        defer { AuthorizedSampleHTTPTransport.configureMock(nil) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let box = ReceiptBox()
        let service = LrcLibService(session: session, captureReceipts: true, receiptObserver: { box.set($0) })
        let task = Task { try await service.lookup(context: .init(title: credit, artist: "", hasYouTubeOrigin: true)) }
        if duringNetwork {
            for _ in 0..<200 where !ReceiptUpstreamMock.started { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(ReceiptUpstreamMock.started)
            try await Task.sleep(for: .milliseconds(50))
        } else { try await Task.sleep(for: .milliseconds(100)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected propagated cancellation") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        for _ in 0..<100 where AuthorizedSampleHTTPTransport.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let receipt = try XCTUnwrap(box.value)
        let cancelled = try XCTUnwrap(receipt.queries.first { $0.outcome == "cancelled" })
        XCTAssertNil(cancelled.returnedCount)
        XCTAssertFalse(cancelled.attempts.isEmpty)
        let phase = try XCTUnwrap(AuthorizedSampleHTTPTransport.requests.first)
        XCTAssertEqual(phase["cancelled"] as? Bool, true)
        if duringNetwork {
            XCTAssertGreaterThanOrEqual(phase["throttleMilliseconds"] as? Double ?? 0, 450)
            XCTAssertGreaterThan(phase["upstreamMilliseconds"] as? Double ?? 0, 0)
        } else {
            XCTAssertTrue(phase["networkStartMonotonicMilliseconds"] is NSNull)
            XCTAssertEqual(phase["upstreamMilliseconds"] as? Double, 0)
            XCTAssertLessThan(phase["throttleMilliseconds"] as? Double ?? 1000, 500)
        }
        XCTAssertTrue(receipt.queries.filter { $0.outcome == "notAttempted" }.allSatisfy { $0.attempts.isEmpty })
    }

    func testOriginalFixed40ProducesAnonymousNativeMockReceipt() async throws {
        ReceiptUpstreamMock.configure("empty")
        AuthorizedSampleHTTPTransport.configureMock(ReceiptUpstreamMock.self)
        defer { AuthorizedSampleHTTPTransport.configureMock(nil) }
        let context = try LyricsLiveReceiptBuilder.context()
        let source = try XCTUnwrap(context["nativeCheckoutSHA"] as? String)
        var rows: [[String: Any]] = [], manifests: [String] = []
        for batch in [1, 2] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixed_lyrics_batch\(batch)", withExtension: "json"))
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            manifests.append(try XCTUnwrap(document["manifestSHA256"] as? String))
            let samples = try XCTUnwrap(document["samples"] as? [[String: Any]])
            XCTAssertEqual(samples.count, 20)
            for (index, sample) in samples.enumerated() {
                AuthorizedSampleHTTPTransport.beginSample(index)
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.httpCookieStorage = nil; config.protocolClasses = [AuthorizedSampleHTTPTransport.self]
                let session = URLSession(configuration: config)
                let suite = "Fixed40NativeReceipt." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: suite) }
                var imported: [String: Any] = ["youtube_id": String(format: "SAMP%07d", index), "title_raw": sample["title"]!, "artist": sample["artist"]!, "playlist_id": "sample", "order": index + 1]
                imported["duration_seconds"] = sample["duration"]
                let song = try XCTUnwrap(MB3PlaylistImporter.parseJSON(try JSONSerialization.data(withJSONObject: ["songs": [imported]])).playlists.first?.songs.first)
                let repository = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults, captureReceipts: true),
                    secondary: LrcApiService(session: session, defaults: defaults, captureReceipts: true), defaults: defaults, secondaryEnabled: { true }, probeBothSources: true)
                let start = ProcessInfo.processInfo.systemUptime
                let report = try await GetLyricsUseCase(repository: repository).executeReport(song: song, includeDurationInQuery: false)
                rows.append(try LyricsLiveReceiptBuilder.row(report, sample: sample, batch: batch,
                    wallMilliseconds: max(0, ProcessInfo.processInfo.systemUptime - start) * 1000, phases: AuthorizedSampleHTTPTransport.requests))
                XCTAssertTrue(AuthorizedSampleHTTPTransport.requests.allSatisfy { $0["transportMode"] as? String == "mock" })
            }
        }
        let receipt: [String: Any] = ["schema": "evantube-fixed40-live-v1", "evidenceKind": "nativeMockResponses", "nativeExecution": true,
            "sourceQueriesAuthorized": false, "realProviderQueries": false, "probeBothSources": true, "independentLookups": true,
            "nativeCheckoutSHA": source, "batchSourceSHA": [source, source], "nativeRunIDs": [context["nativeRunID"] ?? "missing"],
            "batchOrder": [1, 2], "manifestSHA256": manifests, "rows": rows]
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-fixed40-native-mock-receipt"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(rows.count, 40)
        print("FIXED40_NATIVE_MOCK_RECEIPT_COMPLETE 40; zero live queries; no vocal synchronization acceptance")
    }
}

private final class ReceiptBox: @unchecked Sendable {
    private let lock = NSLock(); private var stored: LyricsProviderQueryReceipt?
    func set(_ value: LyricsProviderQueryReceipt) { lock.withLock { stored = value } }
    var value: LyricsProviderQueryReceipt? { lock.withLock { stored } }
}

private final class ReceiptUpstreamMock: URLProtocol {
    private static let lock = NSLock(); private static var mode = "empty", calls: [String: Int] = [:], didStart = false
    private var forwardingTask: Task<Void, Never>?
    static var started: Bool { lock.withLock { didStart } }
    static func configure(_ value: String) { lock.withLock { mode = value; calls = [:]; didStart = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", ["lrclib.net", "api.lrc.cx"].contains(parts.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let primary = parts.host == "lrclib.net"
        let title = parts.queryItems?.first { $0.name == (primary ? "track_name" : "title") }?.value ?? ""
        let key = (parts.host ?? "") + title
        let (mode, number) = Self.lock.withLock { Self.didStart = true; Self.calls[key, default: 0] += 1; return (Self.mode, Self.calls[key]!) }
        forwardingTask = Task { [self] in
            do { try await Task.sleep(for: .milliseconds(mode == "slow" ? 2000 : 20)) } catch { client?.urlProtocol(self, didFailWithError: error); return }
            if mode == "decode", !primary { send(url, status: 200, bytes: Data("{invalid-json".utf8)); return }
            if mode == "retry", !primary, title == "Track", number == 1 { send(url, status: 503, bytes: Data(), headers: ["Retry-After": "0.05"]); return }
            if parts.path == "/api/get" { send(url, status: 404, bytes: Data()); return }
            let lrc = "[00:01.00]Synthetic private-like line\n[00:02.00]Second synthetic line"
            var record: [String: Any] = primary
                ? ["id": 1, "trackName": "Track", "artistName": "Performer feat. Guest", "duration": 200, "syncedLyrics": lrc]
                : ["id": "one", "title": "Track", "artist": "Performer feat. Guest", "duration": 200, "lrc": lrc]
            var records: [[String: Any]] = mode == "empty" || mode == "budget" || title != "Track" ? [] : [record]
            if mode == "truncated", !primary, title == "Performer" {
                records = (1...31).map { ["id": "other-\($0)", "title": "Other", "artist": "Unknown", "lrc": lrc] }
            }
            if mode == "metadata", !primary, title == "Performer" { record["artist"] = ""; records = [record] }
            send(url, status: 200, bytes: try! JSONSerialization.data(withJSONObject: records))
        }
    }
    private func send(_ url: URL, status: Int, bytes: Data, headers: [String: String]? = nil) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { forwardingTask?.cancel() }
}
