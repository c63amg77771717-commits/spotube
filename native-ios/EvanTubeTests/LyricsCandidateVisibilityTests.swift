import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class LyricsCandidateVisibilityTests: XCTestCase {
    private var defaultsBackup: [String: Any] = [:]
    private let keys = ["persistentQueue", "persisted_playback_state", "playerLyricsVisible", "playbackShuffleEnabled", "playbackRepeatMode"]

    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { defaultsBackup[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(false, forKey: "playbackShuffleEnabled")
        UserDefaults.standard.set("off", forKey: "playbackRepeatMode")
    }

    override func tearDown() {
        for key in keys {
            if let value = defaultsBackup[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaultsBackup.removeAll()
        super.tearDown()
    }

    func testProductionRepositoryCandidatesSurviveViewModelLoadingWithNoSelectedLines() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CandidateVisibilityHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let name = "CandidateVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let engine = AudioEngine()
        defer { engine.stop() }
        let song = selected(title: "Candidate fixture", artist: "Fixture performer")
        let vm = model(LrcLibService(session: session, defaults: defaults), engine: engine, song: song)
        vm.isLyricsVisible = true
        await vm.loadLyrics(for: song)
        let result = try XCTUnwrap(vm.lyrics, "FullPlayerView requires this result to present the candidate selector")
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.candidates.map(\.recordID), ["101", "102"])
        XCTAssertNotNil(result.selectionKey)
        XCTAssertTrue(vm.isLyricsVisible)
        XCTAssertFalse(vm.isLoadingLyrics)
        XCTAssertNil(vm.lyricsError)
    }

    func testMissingPerformerSingleCandidateIsRetainedForManualUIConfirmation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CandidateVisibilityHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let name = "SingleCandidateVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let engine = AudioEngine()
        defer { engine.stop() }
        let song = selected(title: "Single fixture", artist: "")
        let vm = model(LrcLibService(session: session, defaults: defaults), engine: engine, song: song)
        await vm.loadLyrics(for: song)
        let result = try XCTUnwrap(vm.lyrics)
        XCTAssertTrue(result.lines.isEmpty, "The missing performer must not be silently inferred")
        XCTAssertEqual(result.candidates.map(\.recordID), ["101"])
        XCTAssertNotNil(result.selectionKey)
    }

    func testAnEmptyRepositoryResultWithoutCandidatesStillProducesMissingLyrics() async {
        let engine = AudioEngine()
        defer { engine.stop() }
        let song = selected(title: "Empty fixture", artist: "Fixture performer")
        let vm = model(NoCandidateContentFixture(), engine: engine, song: song)
        await vm.loadLyrics(for: song)
        XCTAssertNil(vm.lyrics)
        XCTAssertFalse(vm.isLoadingLyrics)
        XCTAssertNil(vm.lyricsError)
    }

    private func selected(title: String, artist: String) -> Song {
        Song(id: "CANDID00001", title: title, artistName: artist, artistId: nil,
             albumName: nil, albumId: nil, duration: 240, thumbnailURL: nil)
    }

    private func model(_ repository: LyricsRepositoryProtocol, engine: AudioEngine, song: Song) -> PlayerViewModel {
        engine.restorePlaybackState(.init(queue: [song], autoplayQueue: [], currentIndex: 0, currentTime: 0,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
        return PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: CandidateVisibilityPlayerFixture()),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }
}

private struct NoCandidateContentFixture: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        SyncedLyrics(lines: [], source: "Empty fixture", isTimeSynced: false)
    }
}

private struct CandidateVisibilityPlayerFixture: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}

private final class CandidateVisibilityHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let title = query.first { $0.name == "track_name" }!.value!
        let artist = query.first { $0.name == "artist_name" }?.value ?? "Fixture performer"
        let first: [String: Any] = ["id": 101, "trackName": title, "artistName": artist,
            "duration": 300.0, "plainLyrics": "First fixture recording"]
        let second: [String: Any] = ["id": 102, "trackName": title, "artistName": artist,
            "duration": 360.0, "plainLyrics": "Second fixture recording"]
        let payload: Any
        if request.url!.lastPathComponent == "search" {
            payload = title == "Single fixture" ? [first] : [first, second]
        } else {
            payload = first
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
