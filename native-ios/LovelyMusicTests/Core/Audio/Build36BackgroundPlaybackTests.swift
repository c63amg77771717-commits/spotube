import AVFoundation
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

    func testMediaCandidateRecoveryDoesNotTreatServiceOrDeviceFailuresAsBadMedia() {
        XCTAssertTrue(PlaybackCandidateFailurePolicy.shouldReject(
            AudioTransferIntegrityError.incompleteResource, httpStatus: 206))
        let decodeError = NSError(domain: AVFoundationErrorDomain,
                                  code: AVError.Code.decodeFailed.rawValue)
        XCTAssertTrue(PlaybackCandidateFailurePolicy.shouldReject(decodeError, httpStatus: nil))
        for status in [401, 403, 429, 500, 503] {
            XCTAssertFalse(PlaybackCandidateFailurePolicy.shouldReject(
                AudioTransferIntegrityError.invalidResponse, httpStatus: status))
            XCTAssertFalse(PlaybackCandidateFailurePolicy.shouldReject(decodeError, httpStatus: status))
        }
        XCTAssertFalse(PlaybackCandidateFailurePolicy.shouldReject(URLError(.timedOut), httpStatus: nil))
        XCTAssertFalse(PlaybackCandidateFailurePolicy.shouldReject(
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.contentIsNotAuthorized.rawValue),
            httpStatus: nil))
        XCTAssertFalse(PlaybackCandidateFailurePolicy.shouldReject(
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue,
                    userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)]),
            httpStatus: nil))
    }

    @MainActor
    func testIncompleteHTTP200ReportsExactCandidateBeforeAutomaticRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Build36IncompleteBodyFixture.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        defer { engine.stop(); session.invalidateAndCancel() }
        let sourceURL = "https://build36-incomplete.example.test/full.m4a"
        let selected = Song(id: "INCOMPL0036", title: "Incomplete fixture", artistName: "Fixture",
                            artistId: nil, albumName: nil, albumId: nil, duration: 240, thumbnailURL: nil)
        engine.streamURLResolver = { _ in (url: sourceURL, contentLength: 8_192) }
        var failures: [(String, String)] = []
        engine.onStreamCandidateFailure = { failures.append(($0, $1)) }
        engine.play(song: selected)
        for _ in 0..<250 where engine.lastError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(engine.lastError)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.0, selected.id)
        XCTAssertEqual(failures.first?.1, sourceURL)
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

    @MainActor
    func testSegmentFailureAfterRefreshReportsNewestCandidateURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Build36RefreshedCandidateFixture.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        defer { engine.stop(); session.invalidateAndCancel() }
        let selected = Song(id: "REFRESH0036", title: "Refresh fixture", artistName: "Fixture",
                            artistId: nil, albumName: nil, albumId: nil, duration: 240, thumbnailURL: nil)
        let firstURL = "https://build36-refresh.example.test/initial.m4a"
        let refreshedURL = "https://build36-refresh.example.test/refreshed.m4a"
        var resolutions = 0
        engine.streamURLResolver = { _ in
            resolutions += 1
            return (url: resolutions == 1 ? firstURL : refreshedURL, contentLength: 6_248)
        }
        var rejected: [String] = []
        engine.onStreamCandidateFailure = { _, url in rejected.append(url) }
        engine.play(song: selected)
        for _ in 0..<250 where engine.lastError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(resolutions, 2, "The sixth segment must use a refreshed descriptor")
        XCTAssertEqual(engine.currentTrack?.streamURL, refreshedURL)
        XCTAssertEqual(rejected, [refreshedURL], "The original descriptor is stale after refresh")
    }

    @MainActor
    func testFullDownloadTimeoutDoesNotReuseSuccessfulProbeStatusOrBytes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Build36TransferTimeoutFixture.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        var rejectedCandidates = 0
        engine.onStreamCandidateFailure = { _, _ in rejectedCandidates += 1 }
        defer {
            engine.stop()
            session.invalidateAndCancel()
        }
        let selected = Song(
            id: "TRTIMEOUT36", title: "Transfer timeout fixture", artistName: "Fixture",
            artistId: nil, albumName: nil, albumId: nil, duration: 240,
            thumbnailURL: nil
        )
        let beganAt = Date()
        engine.streamURLResolver = { _ in
            (url: "https://build36-timeout.example.test/audio.m4a", contentLength: 8_192)
        }
        engine.play(song: selected)
        for _ in 0..<250 where engine.lastError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let events = PlaybackDiagnostics.shared.events.filter {
            $0.videoID == selected.id && $0.timestamp >= beganAt
        }
        let probe = try XCTUnwrap(events.last { $0.phase == .audioTransferProbe })
        XCTAssertEqual(probe.httpStatus, 206)
        XCTAssertEqual(probe.transferReceivedBytes, 4_096)
        let failure = try XCTUnwrap(events.last { $0.phase == .audioTransferFailure })
        XCTAssertEqual(failure.transferStage, .fullDownload)
        XCTAssertEqual(failure.transportErrorCode, URLError.timedOut.rawValue)
        XCTAssertEqual(failure.transferFailure, .network)
        XCTAssertNil(failure.httpStatus, "A timeout has no HTTP response from the new request")
        XCTAssertNil(failure.transferReceivedBytes, "The prior probe bytes are not timeout bytes")
        XCTAssertEqual(failure.transferExpectedBytes, 8_192)
        XCTAssertEqual(rejectedCandidates, 0, "Network timeout must not reject a valid media client")
    }
}

private final class Build36IncompleteBodyFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "build36-incomplete.example.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "4096"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 4_096))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Six indexed segments force the production signed-URL refresh. The last
/// response is incomplete, so no synthetic media is ever installed in AVPlayer.
private final class Build36RefreshedCandidateFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "build36-refresh.example.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let range = request.value(forHTTPHeaderField: "Range") else { return }
        let bounds = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        guard bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]) else { return }
        var body: Data
        if range == "bytes=0-4095" {
            body = Data([
                0, 0, 0, 104, 0x73, 0x69, 0x64, 0x78,
                0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 3, 232,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6,
            ])
            for _ in 0..<6 { body.append(contentsOf: [0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
            body.append(Data(repeating: 0, count: 4_096 - body.count))
        } else {
            body = Data(repeating: 0, count: url.lastPathComponent == "refreshed.m4a"
                        ? 512 : upper - lower + 1)
        }
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(lower)-\(upper)/6248",
                           "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The probe succeeds, then the following whole-resource request fails before
/// receiving a response. No real network, media, cookies, or credentials are used.
private final class Build36TransferTimeoutFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "build36-timeout.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard request.value(forHTTPHeaderField: "Range") == "bytes=0-4095" else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-4095/8192", "Content-Length": "4096"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 4_096))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    func testSuccessfulPlaybackBetweenFailuresRestoresBackgroundSkipBudget() async throws {
        try await withAutomaticSkipEnabled {
            let playableURL = try XCTUnwrap(
                Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a")
            )
            let queue = ["FAIL0000001", "GOOD0000001", "FAIL0000002",
                         "GOOD0000002", "FAIL0000003", "GOOD0000003"].map(song)
            let engine = AudioEngine()
            defer { engine.stop() }
            var playedIDs: [String] = []
            var confirmedIDs: [String] = []
            engine.onPlaybackStarted = { playedIDs.append($0.id) }
            engine.streamURLResolver = { id in
                if id.hasPrefix("FAIL") {
                    throw InnerTubeError.videoUnavailable(reason: "unavailable")
                }
                return (url: playableURL.absoluteString, contentLength: nil)
            }
            let viewModel = model(engine, isForeground: false)
            let resetFailureBudget = engine.onPlaybackConfirmed
            engine.onPlaybackConfirmed = { song in
                // Keep the view model's real budget reset in the exercised path.
                resetFailureBudget?(song)
                confirmedIDs.append(song.id)
            }
            viewModel.play(song: queue[0], fromQueue: queue)

            for playableIndex in [1, 3, 5] {
                let expectedID = queue[playableIndex].id
                for _ in 0..<300 {
                    if engine.currentTrack?.id == expectedID && engine.currentTime > 0.25
                        && playedIDs.contains(expectedID) && confirmedIDs.contains(expectedID) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let observedState = "expected=\(expectedID), current=\(engine.currentTrack?.id ?? "nil"), "
                    + "time=\(engine.currentTime), playing=\(engine.isPlaying), buffering=\(engine.isBuffering), "
                    + "error=\(engine.lastError ?? "nil"), confirmed=\(confirmedIDs), history=\(playedIDs)"
                guard engine.currentTrack?.id == expectedID && engine.currentTime > 0.25
                        && playedIDs.contains(expectedID) && confirmedIDs.contains(expectedID) else {
                    XCTFail("Playback did not both advance and confirm within the existing six-second limit. \(observedState)")
                    return
                }
                XCTAssertTrue(playedIDs.contains(expectedID),
                              "A successfully played song must reach history. \(observedState)")
                XCTAssertTrue(confirmedIDs.contains(expectedID),
                              "A successfully played song must break the failure streak. \(observedState)")
                XCTAssertEqual(engine.currentTrack?.id, expectedID, observedState)
                XCTAssertGreaterThan(engine.currentTime, 0.25,
                                     "Native playback must advance before the next failure. \(observedState)")
                if playableIndex != 5 {
                    // A natural queue advance must not perform the user's
                    // manual-skip reset; success itself has to restore budget.
                    engine.next(userInitiated: false)
                }
            }
            XCTAssertEqual(playedIDs, ["GOOD0000001", "GOOD0000002", "GOOD0000003"],
                           "The separate listening-history callback remains intact")
            XCTAssertEqual(confirmedIDs, ["GOOD0000001", "GOOD0000002", "GOOD0000003"],
                           "Each real playback must reset the background failure budget exactly once")
            XCTAssertNil(viewModel.streamError)
        }
    }

    func testThreeConsecutiveUnavailableTracksStillStopBeforeFourth() async throws {
        try await withAutomaticSkipEnabled {
            let queue = ["FAIL0000011", "FAIL0000012", "FAIL0000013", "FAIL0000014"].map(song)
            let engine = AudioEngine()
            defer { engine.stop() }
            var requestedIDs: [String] = []
            var playedIDs: [String] = []
            engine.onPlaybackStarted = { playedIDs.append($0.id) }
            engine.streamURLResolver = { id in
                requestedIDs.append(id)
                throw InnerTubeError.videoUnavailable(reason: "unavailable")
            }
            let viewModel = model(engine, isForeground: false)
            viewModel.play(song: queue[0], fromQueue: queue)
            for _ in 0..<250 where engine.currentTrack?.id != queue[2].id || engine.lastError == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Longer than the 500ms auto-skip delay: selecting/loading the
            // third broken song must not be mistaken for playback success.
            try await Task.sleep(for: .milliseconds(750))
            XCTAssertEqual(engine.currentTrack?.id, queue[2].id)
            XCTAssertEqual(requestedIDs, Array(queue.prefix(3)).map(\.id))
            XCTAssertFalse(engine.isPlaying)
            XCTAssertTrue(playedIDs.isEmpty)
            XCTAssertNotNil(viewModel.streamError)
        }
    }

    func testQueuedOldPlayerStatusCannotConfirmNewSongWhileResolverIsPending() async throws {
        let playableURL = try XCTUnwrap(
            Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a")
        )
        let first = song("GOODKVO0036")
        let pending = song("WAITKVO0036")
        let engine = AudioEngine()
        defer { engine.stop() }
        var historyIDs: [String] = []
        var confirmedIDs: [String] = []
        var pendingResolverStarted = false
        engine.onPlaybackStarted = { historyIDs.append($0.id) }
        engine.onPlaybackConfirmed = { confirmedIDs.append($0.id) }
        engine.streamURLResolver = { id in
            if id == first.id {
                return (url: playableURL.absoluteString, contentLength: nil)
            }
            pendingResolverStarted = true
            // No item can be installed for the new selection. stop() cancels
            // this suspension, without leaking a checked continuation.
            while true { try await Task.sleep(for: .milliseconds(20)) }
        }
        engine.play(song: first, fromQueue: [first, pending])
        for _ in 0..<250 where historyIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(historyIDs, [first.id])

        // Queue real time-control notifications on the reused player, then
        // change selections before their main-actor callbacks can run.
        for _ in 0..<4 {
            engine.handleRemotePause()
            engine.handleRemotePlay()
        }
        engine.next(userInitiated: false)
        for _ in 0..<100 where !pendingResolverStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(pendingResolverStarted)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(engine.currentTrack?.id, pending.id)
        XCTAssertNil(engine.localFileURL)
        XCTAssertTrue(engine.isBuffering)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(historyIDs, [first.id], "Old-player KVO must not create playback history for a pending song")
        XCTAssertEqual(confirmedIDs, [first.id], "A pending song must not reset the consecutive-failure budget")
    }

    private func withAutomaticSkipEnabled(_ operation: () async throws -> Void) async rethrows {
        let original = UserDefaults.standard.object(forKey: "autoSkipOnError")
        UserDefaults.standard.set(true, forKey: "autoSkipOnError")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "autoSkipOnError")
            } else {
                UserDefaults.standard.removeObject(forKey: "autoSkipOnError")
            }
        }
        try await operation()
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
