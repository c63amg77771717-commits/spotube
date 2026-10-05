import Foundation
import XCTest
@testable import LovelyMusic

@MainActor
final class PlaybackRetryPresentationTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Fixture", artistId: nil, albumName: nil,
             albumId: nil, duration: 180, thumbnailURL: nil)
    }

    private func model(_ engine: AudioEngine) -> PlayerViewModel {
        PlayerViewModel(audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: RetryPresentationPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: RetryPresentationLyricsRepository()),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()))
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected playback state was not reached within 2.5 seconds")
        throw URLError(.timedOut)
    }

    func testFirstTransientFailureDoesNotShowAnErrorWhenTheBoundedRetrySucceeds() async throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        let resolver = RetryPresentationResolver(url: fixture, failures: 1)
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { try await resolver.resolve($0) }
        let vm = model(engine)
        vm.play(song: song("AAAAAAAAAAA"))
        try await wait { engine.lastError != nil }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(vm.streamError, "The first recoverable attempt is still pending its single retry")
        XCTAssertNil(vm.streamErrorCategory)
        try await wait { engine.currentTrack?.streamURL == fixture.absoluteString }
        let count = await resolver.count("AAAAAAAAAAA")
        XCTAssertEqual(count, 2)
        XCTAssertNil(vm.streamError)
    }

    func testFailureAfterTheBoundedRetryStillShowsTheRealError() async throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        let resolver = RetryPresentationResolver(url: fixture, failures: 2)
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { try await resolver.resolve($0) }
        let vm = model(engine)
        vm.play(song: song("AAAAAAAAAAA"))
        try await wait { vm.streamError != nil }
        let count = await resolver.count("AAAAAAAAAAA")
        XCTAssertEqual(count, 2, "A real terminal failure remains visible after the existing one retry")
        XCTAssertNotNil(vm.streamErrorCategory)
    }

    func testChangingTracksCancelsTheOldPendingErrorRetry() async throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        let resolver = RetryPresentationResolver(url: fixture, failures: 1)
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { try await resolver.resolve($0) }
        let vm = model(engine)
        vm.play(song: song("AAAAAAAAAAA"))
        try await wait { engine.lastError != nil }
        try await Task.sleep(for: .milliseconds(40))
        var next = song("BBBBBBBBBBB")
        next.streamURL = fixture.absoluteString
        vm.play(song: next)
        try await Task.sleep(for: .milliseconds(1_150))
        let count = await resolver.count("AAAAAAAAAAA")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(vm.currentSong?.id, next.id)
        XCTAssertNil(vm.streamError)
    }

    func testRestoringAnotherSelectionCannotCarryThePreviousTracksFailure() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { _ in throw URLError(.timedOut) }
        engine.play(song: song("AAAAAAAAAAA"))
        try await wait { engine.lastError != nil }
        let restored = song("BBBBBBBBBBB")
        engine.restorePlaybackState(.init(queue: [restored], autoplayQueue: [], currentIndex: 0,
            currentTime: 0, wasPlaying: false, shuffleEnabled: false,
            repeatMode: AudioEngine.RepeatMode.off.rawValue, savedAt: Date()))
        XCTAssertEqual(engine.currentTrack?.id, restored.id)
        XCTAssertNil(engine.lastError)
        XCTAssertNil(engine.lastFailedSongId)
    }
}

private actor RetryPresentationResolver {
    let url: URL
    let failures: Int
    private var calls: [String: Int] = [:]
    init(url: URL, failures: Int) { self.url = url; self.failures = failures }
    func resolve(_ id: String) throws -> (url: String, contentLength: Int64?) {
        calls[id, default: 0] += 1
        if calls[id, default: 0] <= failures { throw URLError(.timedOut) }
        return (url.absoluteString, nil)
    }
    func count(_ id: String) -> Int { calls[id, default: 0] }
}

private struct RetryPresentationPlayerRepository: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw URLError(.notConnectedToInternet)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}

private struct RetryPresentationLyricsRepository: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? { nil }
}
