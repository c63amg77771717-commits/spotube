import Foundation
import XCTest
@testable import LovelyMusic

/// Build 36: background/lock-screen skips and complete-body HTTP range
/// fallback. All HTTP examples are synthetic and contain no media bytes.
final class Build36AudioProbeTests: XCTestCase {
    private func response(_ status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://cdn.example.test/audio.m4a")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
    }

    func testCorrectPartialProbeRemainsSegmentedAndReportsFullLength() throws {
        let probe = try AudioTransferIntegrity.validateProbe(
            response: response(206, headers: ["Content-Range": "bytes 0-4095/3000000"]),
            receivedBytes: 4096, expectedTotal: 3_000_000
        )
        XCTAssertEqual(probe.totalBytes, 3_000_000)
        XCTAssertFalse(probe.containsFullResource)
    }

    func testIgnoredRangeMayReuseOnlyCompleteKnownResource() throws {
        let probe = try AudioTransferIntegrity.validateProbe(
            response: response(200, headers: ["Content-Length": "3000000"]),
            receivedBytes: 3_000_000, expectedTotal: 3_000_000
        )
        XCTAssertTrue(probe.containsFullResource)
        XCTAssertEqual(probe.totalBytes, 3_000_000)
    }

    func testShortPreviewCannotPassCompleteBodyFallback() {
        XCTAssertThrowsError(try AudioTransferIntegrity.validateProbe(
            response: response(200, headers: ["Content-Length": "400000"]),
            receivedBytes: 400_000, expectedTotal: 3_000_000
        ))
    }

    func testUnknownResourceLengthCannotMakeHTTP200ATrack() {
        XCTAssertThrowsError(try AudioTransferIntegrity.validateProbe(
            response: response(200, headers: ["Content-Length": "400000"]),
            receivedBytes: 400_000, expectedTotal: nil
        ))
    }

    func testMismatchBetweenBodyAndResponseLengthIsRejected() {
        XCTAssertThrowsError(try AudioTransferIntegrity.validateProbe(
            response: response(200, headers: ["Content-Length": "1000000"]),
            receivedBytes: 3_000_000, expectedTotal: 3_000_000
        ))
    }

    func testTypedTransferDiagnosticSurvivesRelaunchWithoutPrivateData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("build36-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(
            phase: .audioTransferFailure, videoID: "AAAAAAAAAAA",
            httpStatus: 200, transferStage: .probe,
            transferFailure: .incompleteResource,
            transferReceivedBytes: 400_000, transferExpectedBytes: 3_000_000
        ))
        let restored = PlaybackDiagnostics(fileURL: file)
        let event = try XCTUnwrap(restored.events.first)
        XCTAssertEqual(event.transferStage, .probe)
        XCTAssertEqual(event.transferFailure, .incompleteResource)
        XCTAssertEqual(event.transferReceivedBytes, 400_000)
        XCTAssertEqual(event.transferExpectedBytes, 3_000_000)
        XCTAssertEqual(event.videoID, "AAAAAAAAAAA")
        let text = String(decoding: try restored.reportData(), as: UTF8.self)
        XCTAssertTrue(text.contains("audioTransferFailure"))
        XCTAssertFalse(text.contains("youtube.com"))
        XCTAssertFalse(text.contains("Cookie"))
    }
}

@MainActor
final class Build36BackgroundSkipTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(
            id: id, title: "Test Song", artistName: "Fixture",
            artistId: nil, albumName: nil, albumId: nil, duration: 240,
            thumbnailURL: nil
        )
    }

    private func model(_ engine: AudioEngine, isForeground: Bool) -> PlayerViewModel {
        PlayerViewModel(
            audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: Build36NullPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: DisabledLyricsRepository()),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()),
            replacementSearcher: { _ in [] },
            isAppForeground: { isForeground }
        )
    }

    func testForegroundKeepsInteractiveReplacementOption() async throws {
        XCTAssertTrue(BackgroundTrackFailurePolicy.shouldWaitForManualReplacement(
            isForeground: true, hasReplacementSearcher: true,
            categoryPermitsReplacement: true))
        XCTAssertFalse(BackgroundTrackFailurePolicy.shouldWaitForManualReplacement(
            isForeground: false, hasReplacementSearcher: true,
            categoryPermitsReplacement: true))
        XCTAssertFalse(BackgroundTrackFailurePolicy.shouldWaitForManualReplacement(
            isForeground: true, hasReplacementSearcher: false,
            categoryPermitsReplacement: true))
    }

    func testBackgroundUnavailableTrackAdvancesToNextWithoutInteractiveSheet() async throws {
        let original = UserDefaults.standard.object(forKey: "autoSkipOnError")
        UserDefaults.standard.set(true, forKey: "autoSkipOnError")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "autoSkipOnError")
            } else {
                UserDefaults.standard.removeObject(forKey: "autoSkipOnError")
            }
        }
        let playableURL = try XCTUnwrap(
            Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a")
        )
        let first = song("AAAAAAAAAAA")
        let next = song("BBBBBBBBBBB")
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { id in
            if id == first.id {
                throw InnerTubeError.videoUnavailable(reason: "unavailable")
            }
            return (url: playableURL.absoluteString, contentLength: nil)
        }
        let viewModel = model(engine, isForeground: false)
        viewModel.play(song: first, fromQueue: [first, next])

        for _ in 0..<180 where engine.currentTrack?.id != next.id {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(engine.currentTrack?.id, next.id,
                       "Background playback must skip one unavailable recording")
    }

    func testForegroundUnavailableTrackDoesNotAutoSkipWhenReplacementAvailable() async throws {
        let original = UserDefaults.standard.object(forKey: "autoSkipOnError")
        UserDefaults.standard.set(true, forKey: "autoSkipOnError")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "autoSkipOnError")
            } else {
                UserDefaults.standard.removeObject(forKey: "autoSkipOnError")
            }
        }
        let first = song("CCCCCCCCCCC")
        let next = song("DDDDDDDDDDD")
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.streamURLResolver = { _ in
            throw InnerTubeError.videoUnavailable(reason: "unavailable")
        }
        let viewModel = model(engine, isForeground: true)
        viewModel.play(song: first, fromQueue: [first, next])
        for _ in 0..<120 where engine.lastError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(engine.lastError)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(engine.currentTrack?.id, first.id,
                       "Foreground keeps the manual alternative-source choice")
    }
}

private struct Build36NullPlayerRepository: PlayerRepositoryProtocol {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        throw InnerTubeError.noStreamAvailable
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? {
        nil
    }
}
