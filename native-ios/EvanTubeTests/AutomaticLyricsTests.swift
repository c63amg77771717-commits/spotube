import XCTest
@testable import LovelyMusic

@MainActor final class AutomaticLyricsTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Artist", artistId: nil, albumName: nil,
             albumId: nil, duration: 180, thumbnailURL: nil)
    }
    private func model(_ repository: LyricsRepositoryProtocol) -> PlayerViewModel {
        PlayerViewModel(audioEngine: AudioEngine(),
            resolveStreamUseCase: ResolveStreamUseCase(repository: AutomaticLyricsPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: repository),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }
    func testLyricsDisplayAutomaticallyEvenWhenLegacyPreferenceIsOffAndNoLyricsExist() async {
        UserDefaults.standard.set(false, forKey: "showLyricsAutomatically")
        let vm = model(AutomaticEmptyLyricsRepository())
        await vm.loadLyrics(for: song("AAAAAAAAAAA"))
        XCTAssertTrue(vm.isLyricsVisible, "No manual lyrics tap is required, even for the empty state")
        XCTAssertFalse(vm.isLoadingLyrics)
        XCTAssertNil(vm.lyrics)
    }
    func testLatePreviousSongResultCannotOverwriteNewSongLyrics() async {
        let repository = AutomaticControlledLyricsRepository()
        let vm = model(repository)
        let old = Task { await vm.loadLyrics(for: song("AAAAAAAAAAA")) }
        await repository.waitForRequest("AAAAAAAAAAA")
        let new = Task { await vm.loadLyrics(for: song("BBBBBBBBBBB")) }
        await repository.waitForRequest("BBBBBBBBBBB")
        await repository.complete("BBBBBBBBBBB")
        await new.value
        await repository.complete("AAAAAAAAAAA")
        await old.value
        XCTAssertEqual(vm.lyrics?.lines.first?.text, "BBBBBBBBBBB")
        XCTAssertFalse(vm.isLoadingLyrics)
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
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        try await withCheckedThrowingContinuation { pending[title] = $0 }
    }
    func waitForRequest(_ title: String) async {
        while pending[title] == nil { await Task.yield() }
    }
    func complete(_ title: String) {
        pending.removeValue(forKey: title)?.resume(returning:
            SyncedLyrics(lines: [LyricLine(time: 0, text: title)], source: "fixture"))
    }
}
