import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class LyricsSecondaryViewModelTests: XCTestCase {
    private var backup: [String: Any] = [:]
    private let keys = ["persistentQueue", "persisted_playback_state", "playerLyricsVisible", "playbackShuffleEnabled", "playbackRepeatMode"]
    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { backup[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: "persistentQueue")
        UserDefaults.standard.set(false, forKey: "playbackShuffleEnabled")
    }
    override func tearDown() {
        for key in keys {
            if let value = backup[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        backup.removeAll()
        super.tearDown()
    }

    func testSongChangeRejectsNonCooperativeLateSecondaryResponseWithoutBlockingPlaybackState() async throws {
        let gate = NonCooperativeLyricsGate()
        let engine = AudioEngine()
        defer { engine.stop() }
        let a = song(id: "OLDSONG0001", title: "Old fixture")
        let b = song(id: "NEWSONG0001", title: "New fixture")
        restore(engine, a)
        let vm = model(engine: engine, repository: gate)
        let oldLoad = Task { await vm.loadLyrics(for: a) }
        try await waitForLookup(gate, title: a.title)
        // Changing playback state is independent of the unresolved lyrics query.
        restore(engine, b)
        XCTAssertEqual(vm.currentSong?.id, b.id)
        await gate.complete(title: b.title, text: "New secondary fixture")
        await vm.loadLyrics(for: b)
        try await waitForDisplayed(vm, text: "New secondary fixture")
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "New secondary fixture")
        await gate.complete(title: a.title, text: "Stale secondary fixture")
        await oldLoad.value
        try await waitForDisplayed(vm, text: "New secondary fixture")
        XCTAssertEqual(vm.currentSong?.id, b.id)
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "New secondary fixture")
        XCTAssertNil(vm.lyricsError)
    }

    func testCallerCancellationRejectsNonCooperativeResponseWithoutMissingLyricsError() async throws {
        let gate = NonCooperativeLyricsGate()
        let engine = AudioEngine()
        defer { engine.stop() }
        let a = song(id: "CANCEL00001", title: "Cancel fixture")
        restore(engine, a)
        let vm = model(engine: engine, repository: gate)
        let load = Task { await vm.loadLyrics(for: a) }
        try await waitForLookup(gate, title: a.title)
        load.cancel()
        await gate.complete(title: a.title, text: "Cancelled secondary fixture")
        await load.value
        XCTAssertNil(vm.lyrics)
        XCTAssertNil(vm.lyricsError)
        XCTAssertFalse(vm.isLoadingLyrics)
    }

    private func waitForDisplayed(_ vm: PlayerViewModel, text: String) async throws {
        for _ in 0..<200 {
            if vm.lyrics?.lines.first?.text == text { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected current song lyrics after observer delivery")
    }
    private func waitForLookup(_ gate: NonCooperativeLyricsGate, title: String) async throws {
        for _ in 0..<200 {
            if await gate.hasPending(title: title) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected pending lyrics lookup")
    }
    private func song(id: String, title: String) -> Song {
        Song(id: id, title: title, artistName: "Fixture performer", artistId: nil,
             albumName: nil, albumId: nil, duration: 240, thumbnailURL: nil)
    }
    private func restore(_ engine: AudioEngine, _ song: Song) {
        engine.restorePlaybackState(.init(queue: [song], autoplayQueue: [], currentIndex: 0, currentTime: 0,
            wasPlaying: false, shuffleEnabled: false, repeatMode: "off", savedAt: Date()))
    }
    private func model(engine: AudioEngine, repository: LyricsRepositoryProtocol) -> PlayerViewModel {
        PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: SecondaryViewModelPlayerFixture()),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }
}

/// Intentionally ignores cancellation so the production VM generation guard is exercised.
private actor NonCooperativeLyricsGate: LyricsRepositoryProtocol {
    private var pending: [String: [CheckedContinuation<SyncedLyrics?, Never>]] = [:]
    private var completed: [String: SyncedLyrics] = [:]
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        if let result = completed[title] { return result }
        return await withCheckedContinuation { continuation in
            pending[title, default: []].append(continuation)
        }
    }
    func hasPending(title: String) -> Bool { !(pending[title] ?? []).isEmpty }
    func complete(title: String, text: String) {
        let result = SyncedLyrics(lines: [LyricLine(time: 0, text: text)], source: "LrcApi (plain)",
                                  isTimeSynced: false, providerID: .lrcapi)
        completed[title] = result
        for continuation in pending.removeValue(forKey: title) ?? [] { continuation.resume(returning: result) }
    }
}

private struct SecondaryViewModelPlayerFixture: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}
