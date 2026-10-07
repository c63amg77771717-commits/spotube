import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class LyricsLookupOutcomeTests: XCTestCase {
    private var preferences: [String: Any] = [:]
    private let preferenceKeys = ["persistentQueue", "persisted_playback_state", "playerLyricsVisible", "playbackShuffleEnabled", "playbackRepeatMode"]
    override func setUp() {
        super.setUp()
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { preferences[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
    }
    override func tearDown() {
        for key in preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        preferences.removeAll(); super.tearDown()
    }
    private func cases() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lyrics_lookup_outcomes", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }
    private func defaults() throws -> UserDefaults {
        let name = "LyricsLookupOutcome-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }
    private func repository() throws -> CompositeLyricsRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutcomeHTTPFixture.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        let store = try defaults()
        return CompositeLyricsRepository(primary: LrcLibService(session: session, defaults: store),
            secondary: LrcApiService(session: session, defaults: store, retryTransient: false), defaults: store, secondaryEnabled: { true })
    }
    private func song(_ row: [String: Any], id: String = "OUTCOME0001") -> Song {
        Song(id: id, title: row["title"] as! String, artistName: row["artist"] as! String,
            artistId: nil, albumName: nil, albumId: nil, duration: 200, thumbnailURL: nil)
    }
    private func model(_ repository: LyricsRepositoryProtocol, engine: AudioEngine, song: Song) -> PlayerViewModel {
        engine.restorePlaybackState(.init(queue: [song], autoplayQueue: [], currentIndex: 0, currentTime: 0,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
        return PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: OutcomePlayerFixture()),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(40)) }

    func testProductionProvidersPreserveAllSixOutcomesAndHTTPProvenance() async throws {
        let rows = try cases()
        XCTAssertEqual(rows.count, 11)
        for row in rows {
            OutcomeHTTPFixture.configure(row)
            let report = try await GetLyricsUseCase(repository: repository()).executeReport(song: song(row))
            XCTAssertEqual(report.state.rawValue, row["expected"] as? String, row["name"] as! String)
            XCTAssertEqual(report.failures.map { $0.providerID.rawValue }, row["failureProviders"] as? [String])
            if let status = row["failureStatus"] as? Int { XCTAssertTrue(report.failures.contains { $0.httpStatus == status }) }
            if row["name"] as? String == "secondary-schema-failed" { XCTAssertEqual(report.failures.last?.reason, .schema) }
            if report.state == .candidatesRejected {
                XCTAssertTrue(report.providers.contains { !$0.rejectionReasons.isEmpty })
                XCTAssertTrue(report.providers.contains { $0.contentCandidateCount > 0 })
                XCTAssertNil(report.lyrics)
                XCTAssertTrue(report.providers.contains { $0.kind == .rejected && $0.receivedCount > 0 })
            }
            if report.state == .providerEmpty { XCTAssertTrue(report.providers.contains { $0.kind == .empty }) }
            if report.state == .manualSelection { XCTAssertTrue(report.lyrics?.lines.isEmpty ?? false) }
            if report.state == .confirmedPlain { XCTAssertFalse(report.lyrics?.isTimeSynced ?? true) }
            if report.state == .synchronized { XCTAssertTrue(report.lyrics?.isTimeSynced ?? false) }
            XCTAssertTrue(OutcomeHTTPFixture.routesWereValid)
        }
    }

    func testPlayerReceivesTypedOutcomesWithoutChangingPlaybackOrCoverChoice() async throws {
        for row in try cases() {
            OutcomeHTTPFixture.configure(row)
            let engine = AudioEngine(); defer { engine.stop() }
            let selected = song(row)
            let vm = model(try repository(), engine: engine, song: selected)
            vm.isLyricsVisible = false
            await vm.loadLyrics(for: selected)
            XCTAssertEqual(vm.lyricsLookupReport?.state.rawValue, row["expected"] as? String)
            XCTAssertEqual(vm.lyricsError != nil, row["expected"] as? String == "sourceUnavailable")
            XCTAssertFalse(vm.isLoadingLyrics)
            XCTAssertFalse(vm.isLyricsVisible)
            XCTAssertFalse(engine.isPlaying)
            XCTAssertEqual(engine.currentTrack?.id, selected.id)
            XCTAssertEqual(engine.currentTime, 0)
            if vm.lyricsLookupReport?.state == .candidatesRejected || vm.lyricsLookupReport?.state == .providerEmpty { XCTAssertNil(vm.lyrics) }
        }
    }

    func testEmptyRejectedAndFailedResultsAreNotPersistentlyNegativeCached() async throws {
        let rows = try cases(), repo = try repository()
        let context = LyricsLookupContext(title: "Song", artist: "Singer", duration: 200)
        for name in ["both-empty", "primary-failure-secondary-rejected", "both-failed"] {
            OutcomeHTTPFixture.configure(try XCTUnwrap(rows.first { $0["name"] as? String == name }))
            let before = try await repo.lookup(context: context)
            XCTAssertNil(before.lyrics)
            OutcomeHTTPFixture.configure(try XCTUnwrap(rows.first { $0["name"] as? String == "secondary-synced" }))
            let after = try await repo.lookup(context: context)
            XCTAssertEqual(after.state, .synchronized)
            XCTAssertGreaterThan(OutcomeHTTPFixture.requestCount, 0)
        }
    }

    func testPartialFailureCanRetryOnForegroundWithoutReplacingTheSong() async throws {
        let rows = try cases()
        let rejected = try XCTUnwrap(rows.first { $0["name"] as? String == "primary-failure-secondary-rejected" })
        OutcomeHTTPFixture.configure(rejected)
        let engine = AudioEngine(); defer { engine.stop() }
        let selected = song(rejected), vm = model(try repository(), engine: engine, song: song(rejected))
        await vm.loadLyrics(for: selected)
        XCTAssertEqual(vm.lyricsLookupReport?.state, .candidatesRejected)
        XCTAssertNil(vm.lyricsError, "A successful secondary response must not become the primary's 503")
        XCTAssertTrue(vm.lyricsLookupReport?.canRetryAvailability ?? false)
        OutcomeHTTPFixture.configure(try XCTUnwrap(rows.first { $0["name"] as? String == "secondary-synced" }))
        vm.retryInterruptedLyrics()
        for _ in 0..<30 {
            await drain()
            if vm.lyricsLookupReport?.state == .synchronized { break }
        }
        XCTAssertEqual(vm.lyricsLookupReport?.state, .synchronized)
        XCTAssertNil(vm.lyricsError)
        XCTAssertEqual(vm.currentSong?.id, selected.id)
        XCTAssertFalse(engine.isPlaying)
    }

    func testProviderCancellationIsNotFailureOrAnEmptyResultAndCanRetry() async throws {
        let rows = try cases(), repo = try repository()
        var cancelled = try XCTUnwrap(rows.first { $0["name"] as? String == "secondary-synced" })
        cancelled["primary"] = ["status": -999, "records": []]
        OutcomeHTTPFixture.configure(cancelled)
        do { _ = try await repo.lookup(context: .init(title: "Song", artist: "Singer", duration: 200)); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        OutcomeHTTPFixture.configure(cancelled)
        let engine = AudioEngine(); defer { engine.stop() }
        let selected = song(cancelled), vm = model(repo, engine: engine, song: song(cancelled))
        await vm.loadLyrics(for: selected)
        XCTAssertNil(vm.lyricsLookupReport); XCTAssertNil(vm.lyricsError)
        XCTAssertFalse(vm.isLoadingLyrics)
        OutcomeHTTPFixture.configure(try XCTUnwrap(rows.first { $0["name"] as? String == "secondary-synced" }))
        vm.retryInterruptedLyrics()
        for _ in 0..<30 { await drain(); if vm.lyricsLookupReport?.state == .synchronized { break } }
        XCTAssertEqual(vm.lyricsLookupReport?.state, .synchronized)
        let result = try await repo.lookup(context: .init(title: "Song", artist: "Singer", duration: 200))
        XCTAssertEqual(result.state, .synchronized)
    }

    func testDisablingSecondaryInFlightDiscardsItsContentAndOutcome() async throws {
        let toggle = OutcomeToggle()
        let primary = OutcomeReportFixture(report: .provider(.lrclib, lyrics: nil, received: 0,
            successfulResponses: 0, failures: [.init(providerID: .lrclib, message: "HTTP 503", httpStatus: 503)]))
        let secondary = OutcomeReportFixture(report: .provider(.lrcapi, lyrics: nil, received: 1,
            successfulResponses: 1, failures: []), onLookup: { toggle.disable() })
        let repo = CompositeLyricsRepository(primary: primary, secondary: secondary,
            defaults: try defaults(), secondaryEnabled: { toggle.enabled })
        let report = try await repo.lookup(context: .init(title: "Song", artist: "Singer", duration: 200))
        XCTAssertEqual(report.state, .sourceUnavailable)
        XCTAssertEqual(report.providers.map(\.providerID), [.lrclib])
    }

    func testLateTypedReportCannotOverwriteTheNewSongsOutcome() async throws {
        let repo = OutcomeControlledRepository(), engine = AudioEngine(); defer { engine.stop() }
        let first = Song(id: "AAAAAAAAAAA", title: "Song", artistName: "Singer", artistId: nil, albumName: nil,
            albumId: nil, duration: 200, thumbnailURL: nil)
        let vm = model(repo, engine: engine, song: first)
        await repo.waitForRequest(first.id)
        let second = Song(id: "BBBBBBBBBBB", title: "Other", artistName: "Singer", artistId: nil, albumName: nil,
            albumId: nil, duration: 200, thumbnailURL: nil)
        engine.restorePlaybackState(.init(queue: [second], autoplayQueue: [], currentIndex: 0, currentTime: 0,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
        await repo.waitForRequest(second.id)
        await repo.complete(second.id, report: .provider(.lrcapi, lyrics: nil, received: 1, successfulResponses: 1, failures: []))
        await drain()
        await repo.complete(first.id, report: .provider(.lrclib, lyrics: nil, received: 0, successfulResponses: 0,
            failures: [.init(providerID: .lrclib, message: "HTTP 503", httpStatus: 503)]))
        await drain()
        XCTAssertEqual(vm.lyricsLookupReport?.state, .candidatesRejected)
        XCTAssertNil(vm.lyricsError)
        XCTAssertEqual(vm.currentSong?.id, second.id)
        XCTAssertFalse(engine.isPlaying)
    }
}

private struct OutcomePlayerFixture: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) { throw URLError(.notConnectedToInternet) }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}
private struct OutcomeReportFixture: LyricsRepositoryProtocol {
    let report: LyricsLookupReport
    var onLookup: (() -> Void)? = nil
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport { onLookup?(); return report }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { try report.legacyValue() }
}
private final class OutcomeToggle: @unchecked Sendable {
    private let lock = NSLock(); private var value = true
    var enabled: Bool { lock.withLock { value } }
    func disable() { lock.withLock { value = false } }
}
private actor OutcomeControlledRepository: LyricsRepositoryProtocol {
    private var pending: [String: CheckedContinuation<LyricsLookupReport, Never>] = [:]
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { nil }
    func lookup(context: LyricsLookupContext) async throws -> LyricsLookupReport {
        await withCheckedContinuation { pending[context.songID!] = $0 }
    }
    func waitForRequest(_ id: String) async { while pending[id] == nil { await Task.yield() } }
    func complete(_ id: String, report: LyricsLookupReport) { pending.removeValue(forKey: id)?.resume(returning: report) }
}

private final class OutcomeHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var row: [String: Any] = [:], count = 0, valid = true
    static func configure(_ value: [String: Any]) { lock.withLock { row = value; count = 0; valid = true } }
    static var requestCount: Int { lock.withLock { count } }
    static var routesWereValid: Bool { lock.withLock { valid } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, first = url.host == "lrclib.net"
        let route = first ? ["/api/get", "/api/search"].contains(url.path) : url.host == "api.lrc.cx" && url.path == "/jsonapi"
        Self.lock.lock(); Self.count += 1; Self.valid = Self.valid && route
        let response = Self.row[first ? "primary" : "secondary"] as! [String: Any]
        Self.lock.unlock()
        var status = response["status"] as! Int
        if status == -999 { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let records = response["records"] as! [[String: Any]]
        let payload: Any
        if first && url.path == "/api/get" {
            if records.isEmpty && status == 200 { status = 404 }
            payload = records.first ?? [:]
        } else { payload = records }
        let data = response["invalidJSON"] as? Bool == true ? Data("not-json".utf8) : try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
