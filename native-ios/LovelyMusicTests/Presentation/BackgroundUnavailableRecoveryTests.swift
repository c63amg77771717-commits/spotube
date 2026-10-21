import Foundation
import XCTest
@testable import LovelyMusic

/// Build36: an unavailable video must not strand lock-screen playback just
/// because the app supports a *foreground-only* replacement-search sheet.
/// All tests use synthetic resolver failures; no real YouTube traffic.
@MainActor
final class BackgroundUnavailableRecoveryTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistName: "Fixture", artistId: nil,
             albumName: nil, albumId: nil, duration: 220, thumbnailURL: nil)
    }

    private func model(_ engine: AudioEngine, appInteractive: Bool,
                       hasReplacementSearcher: Bool = true) -> PlayerViewModel {
        PlayerViewModel(
            audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: RecoveryTestPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: DisabledLyricsRepository()),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()),
            replacementSearcher: hasReplacementSearcher ? { _ in [] } : nil,
            isAppInteractive: { appInteractive }
        )
    }

    private func withAutoSkip(_ enabled: Bool, _ test: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "autoSkipOnError")
        defaults.set(enabled, forKey: "autoSkipOnError")
        defer {
            if let saved { defaults.set(saved, forKey: "autoSkipOnError") }
            else { defaults.removeObject(forKey: "autoSkipOnError") }
        }
        try await test()
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<140 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }

    func testPurePolicyPreservesForegroundChoiceAndBackgroundRecovery() {
        let category = PlaybackErrorCategory.classify("Video unavailable: unavailable")
        XCTAssertEqual(category, .unknown)
        let baseline = (
            isPermanent: true,
            category: category,
            replacementSearchAvailable: true,
            autoSkipEnabled: true,
            queueHasTracks: true
        )
        XCTAssertEqual(UnavailablePlaybackRecoveryPolicy.decide(
            isPermanent: baseline.isPermanent, category: baseline.category,
            replacementSearchAvailable: baseline.replacementSearchAvailable,
            isAppInteractive: true, autoSkipEnabled: baseline.autoSkipEnabled,
            queueHasTracks: baseline.queueHasTracks
        ), .offerManualReplacement)
        XCTAssertEqual(UnavailablePlaybackRecoveryPolicy.decide(
            isPermanent: true, category: category,
            replacementSearchAvailable: true, isAppInteractive: false,
            autoSkipEnabled: true, queueHasTracks: true
        ), .skipImmediately)
        XCTAssertEqual(UnavailablePlaybackRecoveryPolicy.decide(
            isPermanent: true, category: category,
            replacementSearchAvailable: true, isAppInteractive: false,
            autoSkipEnabled: false, queueHasTracks: true
        ), .hold)
        XCTAssertEqual(UnavailablePlaybackRecoveryPolicy.decide(
            isPermanent: true, category: .authRequired,
            replacementSearchAvailable: true, isAppInteractive: false,
            autoSkipEnabled: true, queueHasTracks: true
        ), .hold)
        XCTAssertEqual(UnavailablePlaybackRecoveryPolicy.decide(
            isPermanent: true, category: .noInternet,
            replacementSearchAvailable: true, isAppInteractive: false,
            autoSkipEnabled: true, queueHasTracks: true
        ), .hold)
    }

    func testBackgroundUnavailableTrackImmediatelyAdvancesDespiteReplacementSearch() async throws {
        try await withAutoSkip(true) {
            let first = song("NjTT5_RSkw4")
            let second = song("YgHmuOYK87A")
            let engine = AudioEngine()
            defer { engine.stop() }
            engine.shuffleEnabled = false
            engine.streamURLResolver = { id in
                if id == first.id { throw InnerTubeError.videoUnavailable(reason: "unavailable") }
                try await Task.sleep(for: .seconds(4))
                throw CancellationError()
            }
            let vm = model(engine, appInteractive: false)
            vm.play(song: first, fromQueue: [first, second])
            let didAdvance = await eventually { engine.currentTrack?.id == second.id }
            XCTAssertTrue(didAdvance, "Background must not wait for an inaccessible replacement sheet")
            XCTAssertEqual(engine.currentIndex, 1)
            XCTAssertNil(vm.sourceReplacementSession)
            let recorded = PlaybackDiagnostics.shared.events.contains {
                $0.phase == .autoSkipUnavailable && $0.videoID == first.id
            }
            XCTAssertTrue(recorded, "Record a typed auto-skip event for future exported diagnostics")
        }
    }

    func testForegroundUnavailableTrackRetainsManualReplacementChoice() async throws {
        try await withAutoSkip(true) {
            let first = song("NjTT5_RSkw4")
            let second = song("YgHmuOYK87A")
            let engine = AudioEngine()
            defer { engine.stop() }
            engine.shuffleEnabled = false
            engine.streamURLResolver = { _ in
                throw InnerTubeError.videoUnavailable(reason: "unavailable")
            }
            let vm = model(engine, appInteractive: true)
            vm.play(song: first, fromQueue: [first, second])
            let errorReached = await eventually { vm.streamError != nil }
            XCTAssertTrue(errorReached)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(engine.currentTrack?.id, first.id)
            XCTAssertTrue(vm.canSearchReplacement)
        }
    }

    func testDisabledAutoSkipDoesNotAdvanceBackgroundQueue() async throws {
        try await withAutoSkip(false) {
            let first = song("NjTT5_RSkw4")
            let second = song("YgHmuOYK87A")
            let engine = AudioEngine()
            defer { engine.stop() }
            engine.shuffleEnabled = false
            engine.streamURLResolver = { _ in
                throw InnerTubeError.videoUnavailable(reason: "unavailable")
            }
            let vm = model(engine, appInteractive: false)
            vm.play(song: first, fromQueue: [first, second])
            let errorReached = await eventually { vm.streamError != nil }
            XCTAssertTrue(errorReached)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(engine.currentTrack?.id, first.id)
        }
    }

    func testBackgroundAutoSkipStopsAfterBoundedUnavailableTracks() async throws {
        try await withAutoSkip(true) {
            let queue = [
                song("NjTT5_RSkw4"), song("YgHmuOYK87A"),
                song("a6BcajbX4b0"), song("fBzxBEFMq7c")
            ]
            let engine = AudioEngine()
            defer { engine.stop() }
            engine.shuffleEnabled = false
            engine.streamURLResolver = { _ in
                throw InnerTubeError.videoUnavailable(reason: "unavailable")
            }
            let vm = model(engine, appInteractive: false)
            vm.play(song: queue[0], fromQueue: queue)
            let stopped = await eventually {
                engine.currentIndex == 2 &&
                    vm.streamError?.contains("多首歌曲") == true
            }
            XCTAssertTrue(stopped, "Stop after the existing 3-failure budget; never loop 995 tracks")
            XCTAssertEqual(engine.currentTrack?.id, queue[2].id)
            XCTAssertTrue(PlaybackDiagnostics.shared.events.contains {
                $0.phase == .autoSkipLimitReached && $0.videoID == queue[2].id
            })
        }
    }
}

private struct RecoveryTestPlayerRepository: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw InnerTubeError.noStreamAvailable
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? {
        nil
    }
}
