import XCTest
@testable import LovelyMusic

@MainActor final class AutomaticLyricsTests: XCTestCase {
    private var previousMode: Any?
    override func setUp() {
        super.setUp()
        previousMode = UserDefaults.standard.object(forKey: "playerLyricsVisible")
        UserDefaults.standard.removeObject(forKey: "playerLyricsVisible")
    }
    override func tearDown() {
        if let previousMode { UserDefaults.standard.set(previousMode, forKey: "playerLyricsVisible") }
        else { UserDefaults.standard.removeObject(forKey: "playerLyricsVisible") }
        super.tearDown()
    }
    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Artist", artistId: nil, albumName: nil,
             albumId: nil, duration: 180, thumbnailURL: nil)
    }
    private func model(_ repository: LyricsRepositoryProtocol, engine: AudioEngine? = nil) -> PlayerViewModel {
        let engine = engine ?? AudioEngine()
        if engine.currentTrack == nil { select("AAAAAAAAAAA", engine: engine) }
        return PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: AutomaticLyricsPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }
    private func select(_ id: String?, engine: AudioEngine) {
        engine.restorePlaybackState(.init(queue: id.map { [song($0)] } ?? [], autoplayQueue: [],
            currentIndex: 0, currentTime: 0, wasPlaying: false, shuffleEnabled: false,
            repeatMode: AudioEngine.RepeatMode.off.rawValue, savedAt: Date()))
    }
    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }
    func testActualPlayerEnablesVideoCreditsOnlyForASCIIYouTubeIdentity() async throws {
        let repository = AutomaticIdentityLyricsRepository()
        let engine = AudioEngine()
        let vm = model(repository, engine: engine)
        await drain()
        select("local-song-id", engine: engine)
        await drain()
        select("AAAAAAAAAAé", engine: engine)
        await drain()
        let flags = await repository.flags
        XCTAssertEqual(flags["AAAAAAAAAAA"], true)
        XCTAssertEqual(flags["local-song-id"], false)
        XCTAssertEqual(flags["AAAAAAAAAAé"], false)
        _ = vm
        _ = try await GetLyricsUseCase(repository: repository).execute(title: "default", artist: "Artist")
        let defaultFlag = await repository.flags["default"]
        XCTAssertEqual(defaultFlag, false, "Other callers do not infer video origin from their title strings")
    }
    func testNewInstallationKeepsCoverSelectedWhenLyricsFinishEmpty() async {
        let previous = UserDefaults.standard.object(forKey: "showLyricsAutomatically")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "showLyricsAutomatically") }
            else { UserDefaults.standard.removeObject(forKey: "showLyricsAutomatically") }
        }
        UserDefaults.standard.set(false, forKey: "showLyricsAutomatically")
        let vm = model(AutomaticEmptyLyricsRepository())
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        XCTAssertFalse(vm.isLyricsVisible, "Fetching lyrics must not replace the selected cover")
        XCTAssertFalse(vm.isLoadingLyrics)
        XCTAssertNil(vm.lyrics)
    }
    func testLatePreviousSongResultCannotOverwriteNewSongLyrics() async {
        let repository = AutomaticControlledLyricsRepository()
        let engine = AudioEngine()
        let vm = model(repository, engine: engine)
        await repository.waitForRequest("AAAAAAAAAAA")
        select("BBBBBBBBBBB", engine: engine)
        await repository.waitForRequest("BBBBBBBBBBB")
        await repository.complete("BBBBBBBBBBB")
        await drain()
        await repository.complete("AAAAAAAAAAA")
        await drain()
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "BBBBBBBBBBB")
        let cancelled = await repository.cancelled.contains("AAAAAAAAAAA")
        XCTAssertTrue(cancelled, "Changing songs cancels the old provider task even if it returns late")
        XCTAssertFalse(vm.isLoadingLyrics)
    }
    func testSameAndNewSongPreserveManualCoverChoice() async {
        let engine = AudioEngine()
        let vm = model(AutomaticEmptyLyricsRepository(), engine: engine)
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        vm.isLyricsVisible = false
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        XCTAssertFalse(vm.isLyricsVisible)
        select("BBBBBBBBBBB", engine: engine)
        await drain()
        XCTAssertFalse(vm.isLyricsVisible)
        vm.toggleVideoMode()
        XCTAssertFalse(vm.isLyricsVisible, "The video action remains available while lyrics are automatic")
    }
    func testActualTrackObservationPreservesSelectedModeAcrossTracksAndViewModelRecreation() async throws {
        let engine = AudioEngine()
        let vm = model(AutomaticEmptyLyricsRepository(), engine: engine)
        func select(_ id: String) {
            engine.restorePlaybackState(.init(queue: [song(id)], autoplayQueue: [],
                currentIndex: 0, currentTime: 0, wasPlaying: false, shuffleEnabled: false,
                repeatMode: AudioEngine.RepeatMode.off.rawValue, savedAt: Date()))
        }
        select("AAAAAAAAAAA")
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(vm.isLyricsVisible)
        vm.isLyricsVisible = true
        select("AAAAAAAAAAA")
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(vm.isLyricsVisible)
        select("BBBBBBBBBBB")
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(vm.isLyricsVisible)
        let restored = model(AutomaticEmptyLyricsRepository())
        XCTAssertTrue(restored.isLyricsVisible, "The explicit lyrics selection survives view-model recreation")
        restored.isLyricsVisible = false
        let cover = model(AutomaticEmptyLyricsRepository())
        XCTAssertFalse(cover.isLyricsVisible)
    }
    func testQueuedRetryForOldSongCannotCancelTheNewSongRequest() async {
        let engine = AudioEngine()
        let repository = AutomaticControlledLyricsRepository()
        let vm = model(repository, engine: engine)
        await repository.waitForRequest("AAAAAAAAAAA")
        vm.retryLyrics() // Captures A but has not yet entered the queued task.
        select("BBBBBBBBBBB", engine: engine)
        await repository.waitForRequest("BBBBBBBBBBB")
        await repository.complete("BBBBBBBBBBB")
        await drain()
        await repository.complete("AAAAAAAAAAA")
        await drain()
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "BBBBBBBBBBB")
        XCTAssertNil(vm.lyricsError)
        XCTAssertFalse(vm.isLoadingLyrics)
    }
    func testClearingCurrentTrackRejectsLateLyricsResult() async {
        let engine = AudioEngine()
        let repository = AutomaticControlledLyricsRepository()
        let vm = model(repository, engine: engine)
        await repository.waitForRequest("AAAAAAAAAAA")
        select(nil, engine: engine)
        await drain()
        await repository.complete("AAAAAAAAAAA")
        await drain()
        XCTAssertNil(vm.lyrics)
        XCTAssertNil(vm.lyricsError)
        XCTAssertFalse(vm.isLoadingLyrics)
    }
    func testFailureIsRetryableAndSuccessfulRetryClearsError() async {
        let repository = AutomaticRetryLyricsRepository()
        let vm = model(repository)
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        XCTAssertNotNil(vm.lyricsError)
        XCTAssertFalse(vm.isLyricsVisible, "An error must not change the selected presentation")
        XCTAssertFalse(vm.isLoadingLyrics)
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        XCTAssertNil(vm.lyricsError)
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "retried")
    }

}

private actor AutomaticIdentityLyricsRepository: LyricsRepositoryProtocol {
    var flags: [String: Bool] = [:]
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { nil }
    func getLyrics(title: String, artist: String, duration: Int?, allowVideoCredits: Bool) async throws -> SyncedLyrics? {
        flags[title] = allowVideoCredits
        return nil
    }
}
private struct AutomaticEmptyLyricsRepository: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { nil }
}
private struct AutomaticLyricsPlayerRepository: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}
private actor AutomaticControlledLyricsRepository: LyricsRepositoryProtocol {
    var pending: [String: CheckedContinuation<SyncedLyrics?, Error>] = [:]
    var cancelled = Set<String>()
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        let value: SyncedLyrics? = try await withCheckedThrowingContinuation { pending[title] = $0 }
        if Task.isCancelled { cancelled.insert(title) }
        return value
    }
    func waitForRequest(_ title: String) async {
        while pending[title] == nil { await Task.yield() }
    }
    func complete(_ title: String) {
        pending.removeValue(forKey: title)?.resume(returning:
            SyncedLyrics(lines: [LyricLine(time: 0, text: title)], source: "fixture"))
    }
}

private actor AutomaticRetryLyricsRepository: LyricsRepositoryProtocol {
    private var attempts = 0
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        attempts += 1
        if attempts == 1 { throw URLError(.notConnectedToInternet) }
        return SyncedLyrics(lines: [LyricLine(time: 0, text: "retried")], source: "fixture")
    }
}
