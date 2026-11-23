import XCTest
@testable import LovelyMusic

/// Build52 playback contracts: resume does not seek before it starts, a frozen
/// "playing" status does not refund a lock-screen retry, a backgrounded video
/// player stays detached, and a history row continues through its playlist.
final class Build52PlaybackTests: XCTestCase {
    func testExplicitResumeNeverSeeksBeforeSettingTheRate() {
        XCTAssertFalse(PlaybackInterfaceBudget.seeksBeforeResumeRate(
            resumeNeedsKick: true, playbackLikelyToKeepUp: false))
        XCTAssertFalse(PlaybackInterfaceBudget.seeksBeforeResumeRate(
            resumeNeedsKick: true, playbackLikelyToKeepUp: true))
        XCTAssertFalse(PlaybackInterfaceBudget.seeksBeforeResumeRate(
            resumeNeedsKick: false, playbackLikelyToKeepUp: false))
    }

    func testFrozenPlayingStatusDoesNotRefundTheRetry() {
        var budget = LockedScreenPlaybackRecovery()
        _ = budget.action(playingOpus: false, hasAACFallback: false)
        budget.noteRetryScheduled()
        budget.noteBackoffCancelled(timeAdvanced: false)
        XCTAssertEqual(budget.resolveAttempts, 1)
        XCTAssertFalse(budget.waitingForBackoff)
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .retryAfter(2))
    }

    func testAdvancedPlaybackStillRefundsTheUnusedRetry() {
        var budget = LockedScreenPlaybackRecovery()
        _ = budget.action(playingOpus: false, hasAACFallback: false)
        budget.noteRetryScheduled()
        budget.noteBackoffCancelled(timeAdvanced: true)
        XCTAssertEqual(budget.resolveAttempts, 0)
        XCTAssertEqual(budget.action(playingOpus: false, hasAACFallback: false), .retryAfter(1))
    }

    @MainActor
    func testSuspendedVideoDoesNotLoadANewPlayer() async {
        let manager = VideoPlaybackManager()
        manager.setVideoMode(true)
        manager.videoStreamURLResolver = { (_: String) async throws -> (url: String, contentLength: Int64?)? in
            (url: "https://example.invalid/video", contentLength: nil)
        }
        manager.suspendForBackground()
        manager.loadVideoStream(for: song("VIDEO000052"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(manager.videoPlayer)
        XCTAssertNil(manager.videoPlayerItem)
        XCTAssertTrue(manager.isVideoSuspended)
        XCTAssertEqual(manager.videoLoadState, .idle)
    }

    func testHistoryRowContinuesThroughItsSourcePlaylist() {
        let playlistSongs = [song("SONG0000001"), song("SONG0000002"), song("SONG0000003")]
        let playlist = Playlist(id: "playlist-1", title: "Evening", songs: playlistSongs, isLocal: true)
        var tapped = playlistSongs[1]
        tapped.playbackPlaylistID = playlist.id
        let history = [tapped, song("OTHER000001")]
        let selection = HistoryPlaybackSelection.selection(
            song: tapped, history: history, playlists: [playlist])
        XCTAssertEqual(selection.queue.map(\.id), playlistSongs.map(\.id))
        XCTAssertEqual(selection.song.id, tapped.id)
        XCTAssertEqual(selection.song.playbackPlaylistID, playlist.id)
        XCTAssertEqual(selection.queue[0].playbackPlaylistID, playlist.id)
    }

    func testHistoryRowUsesTheOnlyPlaylistThatContainsTheSong() {
        let owned = [song("SONG0000001"), song("SONG0000002")]
        let playlist = Playlist(id: "playlist-2", title: "Owned", songs: owned, isLocal: true)
        let other = Playlist(id: "playlist-3", title: "Other", songs: [song("SONG0000009")], isLocal: true)
        let tapped = owned[0]
        let selection = HistoryPlaybackSelection.selection(
            song: tapped, history: [tapped], playlists: [playlist, other])
        XCTAssertEqual(selection.queue.map(\.id), owned.map(\.id))
        XCTAssertEqual(selection.song.playbackPlaylistID, playlist.id)
    }

    func testHistoryRowFallsBackToTheVisibleHistoryWhenThePlaylistIsUnknown() {
        let history = [song("SONG0000001"), song("SONG0000002"), song("SONG0000003")]
        let first = Playlist(id: "a", title: "A", songs: [history[0]], isLocal: true)
        let second = Playlist(id: "b", title: "B", songs: [history[0]], isLocal: true)
        let selection = HistoryPlaybackSelection.selection(
            song: history[1], history: history, playlists: [first, second])
        XCTAssertEqual(selection.queue.map(\.id), history.map(\.id))
        XCTAssertEqual(selection.song.id, history[1].id)
    }

    func testTranslatedLyricsGrewOneStep() {
        XCTAssertEqual(LyricsTranslationTypography.rank(for: .small), 4)
        XCTAssertEqual(LyricsTranslationTypography.rank(for: .medium), 5)
        XCTAssertEqual(LyricsTranslationTypography.rank(for: .large), 6)
    }

    private func song(_ id: String) -> Song {
        Song(
            id: id, title: "Test Song", artistName: "Fixture",
            artistId: nil, albumName: nil, albumId: nil, duration: 180,
            thumbnailURL: nil
        )
    }
}
