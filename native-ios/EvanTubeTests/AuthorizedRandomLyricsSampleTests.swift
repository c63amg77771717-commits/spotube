import Foundation
import XCTest
@testable import LovelyMusic

/// Explicit opt-in only. Normal regression runs never contact public providers.
final class AuthorizedRandomLyricsSampleTests: XCTestCase {
    func testCompositionKeysIncludeUncertainTitleRoles() throws {
        func keys(_ title: String, artist: String = "") throws -> Set<String> {
            try compositionKeys(.init(title: title, artist: artist, hasYouTubeOrigin: true))
        }
        let forward = try keys("Singer - Song")
        XCTAssertFalse(forward.isDisjoint(with: try keys("Song - Singer")))
        XCTAssertFalse(forward.isDisjoint(with: try keys("Other Singer - Song (Cover)")))
        XCTAssertFalse(forward.isDisjoint(with: try keys("Song (Live)", artist: "Singer")))
        let bilingual = try keys("Singer【倒流 Revert】Official MV")
        XCTAssertFalse(bilingual.isDisjoint(with: try keys("Revert", artist: "Singer")))
        XCTAssertFalse(bilingual.isDisjoint(with: try keys("倒流", artist: "Singer")))
        XCTAssertFalse(try keys("愛你", artist: "Singer").isDisjoint(with: try keys("爱你", artist: "Singer")))
        XCTAssertFalse(try keys("柯有綸 Alan Kuo - 哭笑不得")
            .isDisjoint(with: try keys("柯有纶 Alan Kuo - 不用擔心")))
        XCTAssertEqual(LyricsLookupMetadata.identityKey("DAVICHI(다비치)"), "davichi다비치")
        XCTAssertEqual(LyricsLookupMetadata.identityKey("ＡＢＣ ♪"), "abc♪")
        XCTAssertTrue(try keys("Singer - First Song", artist: "Singer")
            .isDisjoint(with: try keys("Singer - Second Song", artist: "Singer")))
        XCTAssertTrue(try keys("愛你", artist: "Singer").isDisjoint(with: try keys("不愛你", artist: "Singer")))
    }

    func testAuthorizedFixedTwentySongSampleThroughProductionAdapters() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "authorized_random_lyrics_sample", withExtension: "json") else {
            throw XCTSkip("No explicitly authorized fixed twenty-row sample resource was prepared")
        }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let selected = try XCTUnwrap(document["samples"] as? [[String: Any]])
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(document["seed"] as? Int, 20261006)
        let batch = try XCTUnwrap(document["batch"] as? Int)
        XCTAssertTrue([1, 2].contains(batch))
        // Validate all identities before the first service query, without replacing failed samples.
        var seenCompositions = Set(document["priorCompositionKeys"] as? [String] ?? [])
        for row in selected {
            let context = LyricsLookupContext(title: row["title"] as! String, artist: row["artist"] as! String, hasYouTubeOrigin: true)
            let keys = try compositionKeys(context)
            XCTAssertTrue(seenCompositions.isDisjoint(with: keys), "Composition projections overlap before any query: " + keys.intersection(seenCompositions).sorted().joined(separator: ", "))
            guard seenCompositions.isDisjoint(with: keys) else { throw SampleValidationError.duplicateComposition }
            seenCompositions.formUnion(keys)
        }
        let suite = "AuthorizedLyricsSample-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.protocolClasses = [AuthorizedSampleHTTPTransport.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let repository = CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults),
            secondary: LrcApiService(session: session, defaults: defaults), defaults: defaults, secondaryEnabled: { true }, probeBothSources: true)
        var results: [[String: Any]] = []
        for (index, row) in selected.enumerated() {
            // Only these selected raw metadata fields cross into the test runner.
            let title = try XCTUnwrap(row["title"] as? String), artist = try XCTUnwrap(row["artist"] as? String)
            let duration = row["duration"] as? Int
            XCTAssertFalse(title.isEmpty)
            XCTAssertTrue(Set(row.keys).isSubset(of: ["title", "artist", "duration", "stratum", "sampleKey"]))
            // Reimport through the real importer using a surrogate identity; original video IDs and playlist names are absent.
            var imported: [String: Any] = ["youtube_id": String(format: "SAMP%07d", index), "title_raw": title,
                                          "artist": artist, "playlist_id": "sample", "order": index + 1]
            if let duration { imported["duration_seconds"] = duration }
            let data = try JSONSerialization.data(withJSONObject: ["songs": [imported]])
            let song = try XCTUnwrap(MB3PlaylistImporter.parseJSON(data).playlists.first?.songs.first)
            XCTAssertEqual(song.title, title.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(song.artistName, artist.trimmingCharacters(in: .whitespacesAndNewlines))
            AuthorizedSampleHTTPTransport.beginSample(index)
            let started = ProcessInfo.processInfo.systemUptime
            let report = try await GetLyricsUseCase(repository: repository).executeReport(song: song, includeDurationInQuery: false)
            let lookupMilliseconds = Int(max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000))
            let requests = AuthorizedSampleHTTPTransport.requests
            XCTAssertTrue(requests.allSatisfy { ($0["onlyTitleAndArtist"] as? Bool) == true })
            XCTAssertLessThanOrEqual(requests.count, 24)
            XCTAssertEqual(Set(requests.compactMap { $0["provider"] as? String }), ["lrclib", "lrcapi"])
            XCTAssertTrue(report.providers.allSatisfy { $0.successfulResponses <= 6 })
            if report.state == .synchronized || report.state == .confirmedPlain {
                let selectedIdentity = report.lyrics?.candidates.first { $0.providerID == report.lyrics?.providerID && $0.lyrics.lines.first?.id == report.lyrics?.lines.first?.id }
                XCTAssertEqual(selectedIdentity?.identityDecision?.kind, .confirmed, "Uncertain sample identities must never count as automatic success")
            }
            let providers: [[String: Any]] = try report.providers.map { outcome in
                let evaluated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome.evaluatedCandidates))
                return ["provider": outcome.providerID?.rawValue ?? "unknown", "result": outcome.kind.rawValue,
                 "receivedCount": outcome.receivedCount, "contentCandidateCount": outcome.contentCandidateCount,
                 "acceptedCount": outcome.acceptedCount, "successfulResponses": outcome.successfulResponses,
                 "httpFailures": outcome.failures.compactMap(\.httpStatus), "failureCount": outcome.failures.count,
                 "failures": outcome.failures.map { ["reason": $0.reason.rawValue, "httpStatus": $0.httpStatus.map { $0 as Any } ?? NSNull()] },
                 "rejectionReasons": outcome.rejectionReasons, "evaluatedCandidates": evaluated,
                 "discardedContentOrMetadataCount": max(0, outcome.receivedCount - outcome.contentCandidateCount)]
            }
            let candidates: [[String: Any]] = (report.lyrics?.candidates ?? []).map { candidate in
                ["provider": candidate.providerID.rawValue, "title": candidate.title, "artist": candidate.artist,
                 "identity": candidate.identityDecision?.kind.rawValue ?? "unknown", "timing": candidate.lyrics.timingState.rawValue,
                 "version": candidate.versionLabel, "reason": candidate.identityDecision?.reason?.rawValue ?? "confirmed"]
            }
            results.append(["index": index, "compositionKeys": Array(try compositionKeys(LyricsLookupContext(song: song))).sorted(), "title": title, "artist": artist, "stratum": row["stratum"] ?? "unknown",
                "state": report.state.rawValue, "lookupLatencyMilliseconds": lookupMilliseconds, "providers": providers, "candidates": candidates, "requests": requests,
                "contentRetrieved": report.providers.contains { $0.contentCandidateCount > 0 },
                "automaticIdentity": report.state == .synchronized || report.state == .confirmedPlain,
                "selectionMode": report.state == .synchronized || report.state == .confirmedPlain ? "automatic"
                    : report.state == .manualSelection ? "manual" : report.state == .candidatesRejected ? "rejected" : "noUsableResult",
                "identityHumanGroundTruth": "NOT_RUN", "actualVocalAlignment": "NOT_RUN",
                "manualChoiceVerified": "NOT_RUN", "timestampStructureEvidence": candidates])
        }
        let result: [String: Any] = ["seed": 20261006, "batch": batch, "previousManifestSHA256": document["previousManifestSHA256"] ?? NSNull(), "sampleCount": results.count, "nativeExecution": true,
            "realProviderQueries": true, "probeBothSources": true,
            "realProviderResponses": results.contains { result in
                (result["requests"] as? [[String: Any]] ?? []).contains { ($0["httpStatus"] as? Int ?? 0) > 0 }
            }, "physicalDevice": false, "audioAlignmentValidated": false,
            "newSampleAfterFailures": false, "manifestSHA256": document["manifestSHA256"] ?? "not-provided",
            "results": results]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "EvanTube-authorized-twenty-song-sample-batch-" + String(batch); attachment.lifetime = .keepAlways; add(attachment)
        if let output = ProcessInfo.processInfo.environment["EVANTUBE_SAMPLE_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("AUTHORIZED_RANDOM_LYRICS_SAMPLE_COMPLETE 20; native real provider execution; not physical-device or alignment acceptance")
    }
    private enum SampleValidationError: Error { case duplicateComposition }
    private func compositionKeys(_ context: LyricsLookupContext) throws -> Set<String> {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context))
        let versions = "(?i)\\s*[\\[(][^\\])]*(?:live|remix|acoustic|cover|instrumental|karaoke|demo|remaster|sped\\s*up|slowed|nightcore|現場|演唱會|翻唱)[^\\])]*[\\])]\\s*$"
        return Set(metadata.hypotheses.flatMap(\.titleVariants).map {
            LyricsLookupMetadata.identityKey($0.replacingOccurrences(of: versions, with: "", options: .regularExpression))
        }.filter { !$0.isEmpty })
    }
}

/// Whitelist the two existing APIs and metadata query fields before issuing any live request.
private final class AuthorizedSampleHTTPTransport: URLProtocol {
    private static let lock = NSLock()
    private static var evidence: [[String: Any]] = [], counts: [String: Int] = [:]
    private let taskLock = NSLock(); private var forwarding: Task<Void, Never>?
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
        guard route, !items.isEmpty, items.allSatisfy({ allowed.contains($0.name) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let attempt = Self.lock.withLock { Self.counts[provider, default: 0] += 1; return Self.counts[provider]! }
        guard attempt <= 12 else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let task = Task { [self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
            let upstream = URLSession(configuration: configuration, delegate: AuthorizedSampleNoRedirect(), delegateQueue: nil)
            defer { upstream.invalidateAndCancel() }
            do {
                try await Task.sleep(for: .milliseconds(500))
                var forwarded = request; forwarded.httpShouldHandleCookies = false
                let (data, response) = try await upstream.data(for: forwarded)
                try Task.checkCancellation()
                Self.lock.withLock {
                    Self.evidence.append(["provider": provider, "httpStatus": (response as? HTTPURLResponse)?.statusCode ?? 0,
                        "attempt": attempt, "onlyTitleAndArtist": true,
                        "query": Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })])
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch {
                Self.lock.withLock { Self.evidence.append(["provider": provider, "transportError": (error as NSError).code,
                    "attempt": attempt, "onlyTitleAndArtist": true]) }
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
        // A redirect must not disclose the selected metadata to another endpoint.
        completionHandler(nil)
    }
}
