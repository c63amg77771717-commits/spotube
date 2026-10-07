import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class LrcApiSecondaryRepositoryTests: XCTestCase {
    func testNoPrimaryLyricsFallsBackToRealSecondaryAdapterWithoutPathOrCookies() async throws {
        let f = try SecondaryContext(primary: .status(404), secondary: .json([secondary()]))
        defer { f.close() }
        let result = try await f.lookup()
        XCTAssertEqual(result?.source, "LrcApi")
        XCTAssertEqual(result?.providerID, .lrcapi)
        XCTAssertEqual(result?.lines.first?.text, "Secondary fixture")
        XCTAssertEqual(result?.isTimeSynced, true)
        let requests = f.requests.filter { $0.url?.host == "api.lrc.cx" }
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let names = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)
        XCTAssertEqual(Set(names), Set(["title", "artist"]))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 8)
    }

    func testReliablePrimaryDoesNotQuerySecondary() async throws {
        let f = try SecondaryContext(primary: .json(primary()), secondary: .json([secondary()]))
        defer { f.close() }
        let result = try await f.lookup()
        XCTAssertEqual(result?.providerID, .lrclib)
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
    }

    func testPrimaryTemporaryFailureUsesSecondaryAndRetainsFailureProvenance() async throws {
        for status in [429, 503] {
            let f = try SecondaryContext(primary: .status(status), secondary: .json([secondary()]))
            defer { f.close() }
            let result = try await f.lookup()
            XCTAssertEqual(result?.providerID, .lrcapi)
            XCTAssertEqual(result?.sourceFailures.first?.providerID, .lrclib)
            XCTAssertEqual(f.requests.filter { $0.url?.host == "lrclib.net" }.count, 2)
        }
    }

    func testPrimaryTimeoutWithNoSecondaryLyricsIsUnavailableNotPermanentMissing() async throws {
        let f = try SecondaryContext(primary: .failure(.timedOut), secondary: .json([]))
        defer { f.close() }
        do { _ = try await f.lookup(); XCTFail("Transient failure must remain retryable") }
        catch LyricsLookupError.unavailable(let failures) { XCTAssertEqual(failures.first?.providerID, .lrclib) }
        f.replacePrimary(.status(404))
        let retried = try await f.lookup()
        XCTAssertNil(retried, "A later real no-result response must not inherit a negative cache")
    }

    func testSecondary503AndTimeoutAreErrorsWithBoundedRetryNotMissingLyrics() async throws {
        for failure in [SecondaryReply.status(429), .status(503), .failure(.timedOut)] {
            let f = try SecondaryContext(primary: .status(404), secondary: failure)
            defer { f.close() }
            do { _ = try await f.lookup(); XCTFail("Unavailable secondary cannot become a successful nil") }
            catch LyricsLookupError.unavailable(let failures) { XCTAssertEqual(failures.last?.providerID, .lrcapi) }
            XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 2)
        }
    }

    func testDisabledSecondaryMakesNoSecondaryRequestAndPrimaryFailureStillThrows() async throws {
        let f = try SecondaryContext(primary: .status(503), secondary: .json([secondary()]))
        defer { f.close() }
        f.defaults.set(false, forKey: LyricsSecondarySettings.enabledKey)
        do { _ = try await f.lookup(); XCTFail("Primary error must not be hidden by disabling fallback") }
        catch { XCTAssertTrue(error is LyricsLookupError) }
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
    }

    func testWrongArtistAndVersionsAreRejectedEvenWhenHTTP200DurationMatches() async throws {
        var wrongArtist = secondary(); wrongArtist["artist"] = "Different performer"
        var live = secondary(); live["title"] = "Fixture song (Live)"
        var remix = secondary(); remix["title"] = "Fixture song (Remix)"
        let f = try SecondaryContext(primary: .status(404), secondary: .json([wrongArtist, live, remix]))
        defer { f.close() }
        let result = try await f.lookup()
        XCTAssertNil(result)
    }

    func testDurationMismatchAndUnknownDurationUsePlainWithoutManufacturedTimeline() async throws {
        for duration in [300.0, nil] as [Double?] {
            var record = secondary()
            if let duration { record["duration"] = duration } else { record.removeValue(forKey: "duration") }
            let f = try SecondaryContext(primary: .status(404), secondary: .json([record]))
            defer { f.close() }
            let result = try await f.lookup()
            XCTAssertEqual(result?.isTimeSynced, false)
            XCTAssertTrue(result?.lines.isEmpty ?? false)
            let candidate = try XCTUnwrap(result?.candidates.first)
            XCTAssertEqual(candidate.identityDecision?.score, 75)
            XCTAssertEqual(candidate.lyrics.lines.map(\.text), ["Secondary fixture"])
            XCTAssertEqual(candidate.lyrics.timingState, duration == nil ? .timingUnknown : .durationMismatch)
            XCTAssertTrue(candidate.lyrics.lines.allSatisfy { $0.time == 0 })
        }
    }

    func testLegacyLyricsFieldAndModernTextMarkerArePlainWhenTimingCannotBeTrusted() async throws {
        for body in [["id":"101", "title":"Fixture song", "artist":"Fixture performer", "lyrics":"[00:01.00]Legacy fixture"],
                     ["id":"101", "title":"Fixture song", "artist":"Fixture performer", "lrc":"[!text]Modern plain fixture"]] {
            let f = try SecondaryContext(primary: .status(404), secondary: .json([body]))
            defer { f.close() }
            let result = try await f.lookup()
            XCTAssertEqual(result?.isTimeSynced, false)
            XCTAssertTrue(result?.lines.isEmpty ?? false)
            let candidate = try XCTUnwrap(result?.candidates.first)
            XCTAssertEqual(candidate.identityDecision?.score, 75)
            XCTAssertFalse(candidate.lyrics.lines.first?.text.hasPrefix("[") ?? true)
            XCTAssertEqual(candidate.lyrics.lines.map(\.text), [body["lyrics"] != nil ? "Legacy fixture" : "Modern plain fixture"])
            XCTAssertTrue(candidate.lyrics.lines.allSatisfy { $0.time == 0 })
        }
    }

    func testOutOfBoundsTimestampCannotUseSyncedHighlighting() async throws {
        var body = secondary(); body["lrc"] = "[99:00.04]Fixture outlier"
        let f = try SecondaryContext(primary: .status(404), secondary: .json([body]))
        defer { f.close() }
        let result = try await f.lookup()
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertEqual(result?.lines.first?.time, 0)
    }

    func testProviderIDCollisionChoicesAndSelectionSurviveRecreatedRepository() async throws {
        var p = primary(); p["duration"] = 300.0
        let f = try SecondaryContext(primary: .json(p), secondary: .json([secondary()]))
        defer { f.close() }
        let loaded = try await f.lookup()
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(Set(result.candidates.map(\.id)).count, 2, "Both providers' record 101 must survive")
        XCTAssertEqual(result.providerID, .lrcapi)
        XCTAssertEqual(result.lines.map(\.text), ["Secondary fixture"])
        XCTAssertEqual(result.candidates.map { $0.identityDecision?.score }, [95, 75])
        XCTAssertEqual(Set(result.candidates.flatMap { $0.lyrics.lines.map(\.text) }), ["Primary fixture", "Secondary fixture"])
        let chosen = LyricsRecordID(providerID: .lrcapi, recordID: "101")
        LyricsSelectionStore.select(chosen, for: try XCTUnwrap(result.selectionKey), defaults: f.defaults)
        let recreated = f.repository()
        let restored = try await f.lookup(repository: recreated)
        XCTAssertEqual(restored?.providerID, .lrcapi)
        XCTAssertEqual(restored?.lines.map(\.text), ["Secondary fixture"])
        XCTAssertEqual(restored?.lines.map(\.time), [1], "Use one complete chosen provider timeline")
    }

    func testLegacyIntIDMigratesWithoutDiscardingLRCLibChoiceOrCollidingWithSecondary() async throws {
        var p = primary(); p["duration"] = 300.0
        let f = try SecondaryContext(primary: .json(p), secondary: .json([secondary()]))
        defer { f.close() }
        let key = LyricsMatchingPolicy.selectionKey(title: f.title, artist: f.artist, duration: 240)
        f.defaults.set(101, forKey: "lyrics.selection." + key)
        let result = try await f.lookup()
        XCTAssertEqual(result?.providerID, .lrclib)
        XCTAssertEqual(result?.lines.first?.text, "Primary fixture")
        let migrated = try XCTUnwrap(f.defaults.dictionary(forKey: "lyrics.selection." + key))
        XCTAssertEqual(migrated["providerID"] as? String, "lrclib")
        XCTAssertEqual(migrated["recordID"] as? String, "101")
        XCTAssertTrue(f.requests.contains { $0.url?.host == "api.lrc.cx" },
                      "Plain primary can offer fallback candidates while retaining the explicit primary choice")
    }

    func testSavedSecondaryChoiceStillRestoresWhenPrimaryBecomesReliable() async throws {
        let f = try SecondaryContext(primary: .json(primary()), secondary: .json([secondary()]))
        defer { f.close() }
        let key = LyricsMatchingPolicy.selectionKey(title: f.title, artist: f.artist, duration: 240)
        LyricsSelectionStore.select(.init(providerID: .lrcapi, recordID: "101"), for: key, defaults: f.defaults)
        let result = try await f.lookup()
        XCTAssertEqual(result?.providerID, .lrcapi)
        XCTAssertEqual(result?.lines.first?.text, "Secondary fixture")
    }

    func testMissingArtistAlwaysNeedsManualSelectionAndNeverSendsEmptyArtist() async throws {
        let f = try SecondaryContext(primary: .status(404), secondary: .json([secondary()]), artist: "")
        defer { f.close() }
        let result = try await f.lookup()
        XCTAssertNil(result, "English40 + duration20 =60 is below the manual threshold")
        var hanRecord = secondary(); hanRecord["title"] = "測試歌曲"
        let han = try SecondaryContext(primary: .status(404), secondary: .json([hanRecord]), title: "測試歌曲", artist: "")
        defer { han.close() }
        let manual = try await han.lookup()
        XCTAssertTrue(manual?.lines.isEmpty ?? false)
        XCTAssertEqual(manual?.candidates.count, 1)
        XCTAssertEqual(manual?.candidates.first?.identityDecision?.score, 65)
        XCTAssertEqual(manual?.candidates.first?.lyrics.lines.map(\.text), ["Secondary fixture"])
        let requests = (f.requests + han.requests).filter { $0.url?.host == "api.lrc.cx" }
        XCTAssertTrue(requests.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.allSatisfy { $0.name != "artist" }
        })
    }

    func testCollaborationSeparatorsMatchButNeverCollapseGuestIdentityOrLiveVersion() {
        XCTAssertEqual(LyricsLookupMetadata.matchingPerformerKey("汪蘇瀧/單依純"),
                       LyricsLookupMetadata.matchingPerformerKey("汪苏泷 & 单依纯"))
        XCTAssertNotEqual(LyricsLookupMetadata.matchingPerformerKey("Artist A/B"),
                          LyricsLookupMetadata.matchingPerformerKey("Artist AB"))
        XCTAssertFalse(LyricsMatchingPolicy.identityMatches(title: "Song", artist: "Fixture performer",
            pair: .init(title: "Song (Live)", artist: "Fixture performer")))
    }

    func testCancellationDuringPrimaryStopsTransportAndPreventsFallback() async throws {
        var slow = SecondaryReply.status(404); slow.delayMS = 10_000
        let f = try SecondaryContext(primary: slow, secondary: .json([secondary()]))
        defer { f.close() }
        let task = Task { try await f.lookup() }
        try await waitForRequest(f, host: "lrclib.net")
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
        try await waitForTransportStop(f)
        XCTAssertGreaterThan(f.stopCount, 0)
    }

    func testCancellationDuringSecondaryStopsTransportAndDoesNotReturnLyricsOrRetry() async throws {
        var slow = SecondaryReply.json([secondary()]); slow.delayMS = 10_000
        let f = try SecondaryContext(primary: .status(404), secondary: slow)
        defer { f.close() }
        let task = Task { try await f.lookup() }
        try await waitForRequest(f, host: "api.lrc.cx")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled response cannot surface lyrics") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 1)
        try await waitForTransportStop(f)
        XCTAssertGreaterThan(f.stopCount, 0)
    }

    func testFormalAndLegacyPrimary503UseSecondaryAndKeepOriginalFailure() async throws {
        for formal in [false, true] {
            let f = try SecondaryContext(primary: .status(503), secondary: .json([secondary()]))
            defer { f.close() }
            let context = f.formalContext()
            let result: SyncedLyrics?
            if formal { result = try await f.lookupFormal(context: context) }
            else { result = try await f.lookup() }
            XCTAssertEqual(result?.providerID, .lrcapi)
            XCTAssertEqual(result?.lines.first?.text, "Secondary fixture")
            XCTAssertEqual(result?.sourceFailures.count, 1)
            XCTAssertEqual(result?.sourceFailures.first?.providerID, .lrclib)
            XCTAssertEqual(result?.sourceFailures.first?.message, PublicSourceError.http("LRCLib", 503).localizedDescription)
            XCTAssertEqual(f.requests.filter { $0.url?.host == "lrclib.net" }.count, 2)
            XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 1)
            emit503Report("success-" + (formal ? "context" : "legacy"), f: f, context: context,
                          failures: result?.sourceFailures ?? [], result: "secondary-success")
        }
    }

    func testFormalAndLegacyPrimary503SecondaryEmptyRemainUnavailableWithOneSourceLabel() async throws {
        for formal in [false, true] {
            let f = try SecondaryContext(primary: .status(503), secondary: .json([]))
            defer { f.close() }
            let context = f.formalContext()
            do {
                if formal { _ = try await f.lookupFormal(context: context) }
                else { _ = try await f.lookup() }
                XCTFail("A 503 cannot become a successful missing-lyrics result")
            } catch let error as LyricsLookupError {
                guard case .unavailable(let failures) = error else { return }
                XCTAssertEqual(failures.map(\.providerID), [.lrclib])
                XCTAssertEqual(failures.first?.message, PublicSourceError.http("LRCLib", 503).localizedDescription)
                XCTAssertEqual(error.localizedDescription, PublicSourceError.http("LRCLib", 503).localizedDescription)
                XCTAssertEqual(error.localizedDescription.components(separatedBy: "LRCLib").count - 1, 1)
                if formal {
                    XCTAssertTrue(LyricsLookupDiagnostics.shared.events.contains {
                        $0.lookupID == context.diagnosticLookupID && $0.provider == .lrcapi && $0.phase == .providerEmpty
                    }, "The secondary did run even though the terminal failure names only LRCLib")
                }
                emit503Report("empty-" + (formal ? "context" : "legacy"), f: f, context: context,
                              failures: failures, result: "unavailable", terminal: error.localizedDescription)
            }
            XCTAssertEqual(f.requests.filter { $0.url?.host == "lrclib.net" }.count, 2)
            XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 1)
        }
    }

    func testFormalPrimary503AndSecondaryErrorPreserveIndependentSourceFailures() async throws {
        for (name, reply) in [("503", SecondaryReply.status(503)), ("timeout", SecondaryReply.failure(.timedOut))] {
            let f = try SecondaryContext(primary: .status(503), secondary: reply)
            defer { f.close() }
            let context = f.formalContext()
            do { _ = try await f.lookupFormal(context: context); XCTFail("Both source errors must remain visible") }
            catch let error as LyricsLookupError {
                guard case .unavailable(let failures) = error else { return }
                XCTAssertEqual(failures.map(\.providerID), [.lrclib, .lrcapi])
                XCTAssertEqual(failures.first?.message, PublicSourceError.http("LRCLib", 503).localizedDescription)
                XCTAssertEqual(error.localizedDescription.components(separatedBy: "LRCLib").count - 1, 1)
                XCTAssertEqual(error.localizedDescription.components(separatedBy: "LrcApi").count - 1, 1)
                if name == "503" {
                    XCTAssertEqual(failures.last?.message, PublicSourceError.http("LrcApi", 503).localizedDescription)
                }
                emit503Report("secondary-error-" + name, f: f, context: context,
                              failures: failures, result: "unavailable", terminal: error.localizedDescription)
            }
            XCTAssertEqual(f.requests.filter { $0.url?.host == "lrclib.net" }.count, 2)
            XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 2)
        }
    }

    func testFormalPrimary503WithSecondaryDisabledDoesNotRequestItOrLoseSelection() async throws {
        let f = try SecondaryContext(primary: .status(503), secondary: .json([secondary()]))
        defer { f.close() }
        let context = f.formalContext()
        let saved = LyricsRecordID(providerID: .lrcapi, recordID: "remembered-secondary")
        LyricsSelectionStore.select(saved, for: context.selectionKey, defaults: f.defaults)
        f.defaults.set(false, forKey: LyricsSecondarySettings.enabledKey)
        do { _ = try await f.lookupFormal(context: context); XCTFail("Primary failure must not become nil") }
        catch let error as LyricsLookupError {
            guard case .unavailable(let failures) = error else { return }
            XCTAssertEqual(failures.map(\.providerID), [.lrclib])
            XCTAssertEqual(error.localizedDescription, PublicSourceError.http("LRCLib", 503).localizedDescription)
            emit503Report("secondary-disabled", f: f, context: context,
                          failures: failures, result: "unavailable", terminal: error.localizedDescription)
        }
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
        XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: context.selectionKey, defaults: f.defaults), saved)
        XCTAssertTrue(LyricsLookupDiagnostics.shared.events.contains {
            $0.lookupID == context.diagnosticLookupID && $0.provider == .lrcapi && $0.reason == .secondaryDisabled
        })
    }

    func testFormalPrimary503ThenSecondaryCancellationStopsWithoutLyricsOrRetry() async throws {
        var slow = SecondaryReply.json([secondary()]); slow.delayMS = 10_000
        let f = try SecondaryContext(primary: .status(503), secondary: slow)
        defer { f.close() }
        let context = f.formalContext()
        let task = Task { try await f.lookupFormal(context: context) }
        try await waitForRequest(f, host: "api.lrc.cx")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled fallback must not surface stale lyrics") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(f.requests.filter { $0.url?.host == "lrclib.net" }.count, 2)
        XCTAssertEqual(f.requests.filter { $0.url?.host == "api.lrc.cx" }.count, 1)
        try await waitForTransportStop(f)
        XCTAssertGreaterThan(f.stopCount, 0)
        emit503Report("secondary-cancelled", f: f, context: context, failures: [], result: "cancelled")
    }

    func testFormalPrimary503SwitchOffDuringFallbackDiscardsItAndRecordsDisabled() async throws {
        var slow = SecondaryReply.json([secondary()]); slow.delayMS = 2_000
        let f = try SecondaryContext(primary: .status(503), secondary: slow)
        defer { f.close() }
        let context = f.formalContext()
        let task = Task { try await f.lookupFormal(context: context) }
        try await waitForRequest(f, host: "api.lrc.cx")
        f.defaults.set(false, forKey: LyricsSecondarySettings.enabledKey)
        do { _ = try await task.value; XCTFail("Disabled secondary response must not replace primary failure") }
        catch let error as LyricsLookupError {
            guard case .unavailable(let failures) = error else { return }
            XCTAssertEqual(failures.map(\.providerID), [.lrclib])
            XCTAssertEqual(error.localizedDescription, PublicSourceError.http("LRCLib", 503).localizedDescription)
            emit503Report("secondary-disabled-in-flight", f: f, context: context,
                          failures: failures, result: "unavailable", terminal: error.localizedDescription)
        }
        XCTAssertTrue(LyricsLookupDiagnostics.shared.events.contains {
            $0.lookupID == context.diagnosticLookupID && $0.provider == .lrcapi && $0.reason == .secondaryDisabled
        })
    }

    private func emit503Report(_ name: String, f: SecondaryContext, context: LyricsLookupContext,
                               failures: [LyricsSourceFailure], result: String, terminal: String? = nil) {
        let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == context.diagnosticLookupID }
        let raw = PublicSourceError.http("LRCLib", 503).localizedDescription
        let report: [String: Any] = ["case": name, "result": result,
            "primaryTransportCalls": f.requests.filter { $0.url?.host == "lrclib.net" }.count,
            "secondaryTransportCalls": f.requests.filter { $0.url?.host == "api.lrc.cx" }.count,
            "failureProviders": failures.map { $0.providerID.rawValue },
            "failureMessages": failures.map(\.message), "terminalError": terminal ?? "",
            "secondaryEmptyObserved": events.contains { $0.provider == .lrcapi && $0.phase == .providerEmpty },
            "secondaryDisabledObserved": events.contains { $0.provider == .lrcapi && $0.reason == .secondaryDisabled },
            "build22WrappingReproduction": "LRCLib: LRCLib: " + raw,
            "newLiveProviderCalls": 0, "syntheticLyrics": true]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print("BUILD23_503_REPORT " + String(decoding: data, as: UTF8.self))
        }
    }

    // URLSession cancellation can finish its async continuation before URLProtocol.stopLoading.
    // Await that transport callback explicitly instead of assuming their queue ordering.
    private func waitForTransportStop(_ f: SecondaryContext) async throws {
        for _ in 0..<200 {
            if f.stopCount > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Cancelled fixture transport did not stop")
    }

    private func waitForRequest(_ f: SecondaryContext, host: String) async throws {
        for _ in 0..<200 {
            if f.requests.contains(where: { $0.url?.host == host }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fixture request did not start")
    }
    private func primary() -> [String: Any] {
        ["id":101,"trackName":"Fixture song","artistName":"Fixture performer","duration":240.0,
         "syncedLyrics":"[00:02.00]Primary fixture"]
    }
    private func secondary() -> [String: Any] {
        ["id":"101","title":"Fixture song","artist":"Fixture performer","duration":240.0,
         "lrc":"[00:01.00]Secondary fixture"]
    }
}

private struct SecondaryReply {
    var status: Int = 200
    var payload: Any?
    var error: URLError.Code?
    var delayMS: Int = 0
    static func status(_ status: Int) -> Self { Self(status: status) }
    static func json(_ body: Any) -> Self { Self(payload: body) }
    static func failure(_ error: URLError.Code) -> Self { Self(error: error) }
}

private final class SecondaryContext {
    let title: String
    let artist: String
    let session: URLSession
    let defaults: UserDefaults
    private let suite: String
    init(primary: SecondaryReply, secondary: SecondaryReply, title: String = "Fixture song", artist: String = "Fixture performer") throws {
        self.title = title; self.artist = artist
        let suiteName = "LrcApiSecondaryTests." + UUID().uuidString
        suite = suiteName
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [SecondaryHTTPFixture.self]
        session = URLSession(configuration: configuration)
        SecondaryHTTPFixture.state.configure(primary: primary, secondary: secondary)
    }
    var requests: [URLRequest] { SecondaryHTTPFixture.state.requests }
    var stopCount: Int { SecondaryHTTPFixture.state.stopCount }
    func close() { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: suite) }
    func replacePrimary(_ reply: SecondaryReply) { SecondaryHTTPFixture.state.replacePrimary(reply) }
    func repository() -> CompositeLyricsRepository {
        CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: defaults),
            secondary: LrcApiService(session: session, defaults: defaults), defaults: defaults)
    }
    func formalContext() -> LyricsLookupContext {
        .init(songID: "fixture5031", title: title, artist: artist, duration: 240, hasYouTubeOrigin: true)
    }
    func lookupFormal(context: LyricsLookupContext) async throws -> SyncedLyrics? {
        try await repository().getLyrics(context: context)
    }
    func lookup(repository: CompositeLyricsRepository? = nil) async throws -> SyncedLyrics? {
        try await (repository ?? self.repository()).getLyrics(title: title, artist: artist,
                                                              duration: 240, allowVideoCredits: true)
    }
}

private final class SecondaryHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var primary = SecondaryReply.status(404)
    private var secondary = SecondaryReply.json([])
    private var captured: [URLRequest] = []
    private var stopped = 0
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    func configure(primary: SecondaryReply, secondary: SecondaryReply) {
        lock.lock(); defer { lock.unlock() }
        self.primary = primary; self.secondary = secondary; captured = []; stopped = 0
    }
    func replacePrimary(_ reply: SecondaryReply) { lock.lock(); defer { lock.unlock() }; primary = reply }
    func record(_ request: URLRequest) -> SecondaryReply {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
        var reply = request.url!.host == "lrclib.net" ? primary : secondary
        if request.url!.lastPathComponent == "search", let body = reply.payload as? [String: Any] { reply.payload = [body] }
        return reply
    }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped += 1 }
}

private final class SecondaryHTTPFixture: URLProtocol {
    static let state = SecondaryHTTPState()
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.record(request)
        responseTask = Task {
            if reply.delayMS > 0 {
                do { try await Task.sleep(for: .milliseconds(reply.delayMS)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            if let code = reply.error { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                           headerFields: ["Retry-After":"0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body = reply.payload { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel(); Self.state.stop() }
}
