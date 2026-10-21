import Foundation
import XCTest

@testable import LovelyMusic

/// HTTP-200 descriptors are only candidates until their media loads. These
/// synthetic responses never contact YouTube or contain user diagnostics.
final class MediaCandidateRecoveryTests: XCTestCase {
    func testReportedMediaFailureMovesFromSessionToVisionOSFullAAC() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let initial = try await resolve(repository, videoID: "song")
        XCTAssertTrue(initial.remoteURL.path.contains("session-0-medium"))

        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: initial.remoteURL.absoluteString
        )
        let recovered = try await resolve(repository, videoID: "song")

        XCTAssertTrue(recovered.remoteURL.path.contains("visionOS-0-medium"))
        XCTAssertEqual(recovered.mimeType, "audio/mp4")
        XCTAssertEqual(recovered.duration, .seconds(200))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS"])
    }

    func testUnknownAndReplacedURLsCannotRejectNewCandidate() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let old = try await resolve(repository, videoID: "song")
        await api.setSessionRevision(1)
        let replacement = try await resolve(repository, videoID: "song")
        XCTAssertNotEqual(old.remoteURL, replacement.remoteURL)

        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: "https://media.example.test/unknown.m4a"
        )
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: old.remoteURL.absoluteString
        )
        let next = try await resolve(repository, videoID: "song")

        XCTAssertEqual(next.remoteURL, replacement.remoteURL)
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "session", "session"])
    }

    func testFailureIsScopedToTheObservedVideo() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let first = try await resolve(repository, videoID: "first")
        repository.reportPlaybackCandidateFailure(
            videoId: "second", streamURL: first.remoteURL.absoluteString
        )
        repository.reportPlaybackCandidateFailure(
            videoId: "first", streamURL: first.remoteURL.absoluteString
        )

        let second = try await resolve(repository, videoID: "second")
        let firstRetry = try await resolve(repository, videoID: "first")

        XCTAssertTrue(second.remoteURL.path.contains("session"))
        XCTAssertTrue(firstRetry.remoteURL.path.contains("visionOS"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "session", "visionOS"])
    }

    func testRejectionVersionDoesNotJoinAnOlderInflightRequest() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let initial = try await resolve(repository, videoID: "song")
        let oldStarted = expectation(description: "old generation session request parked")
        await api.suspendSession { oldStarted.fulfill() }
        let oldRequest = Task {
            try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .medium, requestHeaders: [:]
            )
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: initial.remoteURL.absoluteString
        )

        let recoveredBeforeOldReleased = expectation(description: "new generation resolves independently")
        let newRequest = Task {
            let result = try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .medium, requestHeaders: ["X-Test": "new"]
            )
            recoveredBeforeOldReleased.fulfill()
            return result
        }
        await fulfillment(of: [recoveredBeforeOldReleased], timeout: 2)
        // Release even after an expectation failure so a regression cannot
        // leave the old synthetic request hanging in the test process.
        await api.releaseSession()
        let recovered = try await newRequest.value
        let obsolete = try await oldRequest.value

        XCTAssertTrue(recovered.remoteURL.path.contains("visionOS"))
        XCTAssertEqual(recovered.requestHeaders["X-Test"], "new")
        repository.reportPlaybackCandidateSuccess(
            videoId: "song", streamURL: obsolete.remoteURL.absoluteString
        )
        let next = try await resolve(repository, videoID: "song")
        XCTAssertTrue(next.remoteURL.path.contains("visionOS"), "Old completion must not overwrite provenance")
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "session", "visionOS", "visionOS"])
    }

    func testConcurrentQualitiesRemainIndependentAndTrackTheirOwnURLs() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let bothStarted = expectation(description: "two quality requests parked")
        bothStarted.expectedFulfillmentCount = 2
        await api.suspendSession { bothStarted.fulfill() }
        let lowRequest = Task {
            try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .low, requestHeaders: ["X-Test": "low"]
            )
        }
        let highRequest = Task {
            try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .high, requestHeaders: ["X-Test": "high"]
            )
        }
        await fulfillment(of: [bothStarted], timeout: 2)
        await api.releaseSession()
        let low = try await lowRequest.value
        let high = try await highRequest.value
        XCTAssertEqual(low.itag, 139)
        XCTAssertEqual(high.itag, 141)
        XCTAssertEqual(low.requestHeaders["X-Test"], "low")
        XCTAssertEqual(high.requestHeaders["X-Test"], "high")

        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: low.remoteURL.absoluteString
        )
        let recovered = try await resolve(repository, videoID: "song", quality: .high)
        XCTAssertEqual(recovered.itag, 141)
        XCTAssertTrue(recovered.remoteURL.path.contains("visionOS"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "session", "visionOS"])
    }

    func testAllReportedCandidatesExhaustWithoutRepeatingNetworkRequests() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        for client in ["session", "visionOS", "IOS", "WEB_REMIX"] {
            let descriptor = try await resolve(repository, videoID: "song")
            XCTAssertTrue(descriptor.remoteURL.path.contains("/\(client)-"))
            repository.reportPlaybackCandidateFailure(
                videoId: "song", streamURL: descriptor.remoteURL.absoluteString
            )
        }

        for _ in 0..<3 {
            do {
                _ = try await resolve(repository, videoID: "song")
                XCTFail("Every known candidate has already failed")
            } catch let error as InnerTubeError {
                guard case .noStreamAvailable = error else {
                    return XCTFail("Expected bounded exhaustion, got \(error)")
                }
            }
        }
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS", "IOS", "WEB_REMIX"])
    }

    func testOnlyObservedSuccessfulURLClearsTemporaryExclusions() async throws {
        let api = MediaCandidateAPI()
        let repository = PlayerRepository(api: api)
        let failed = try await resolve(repository, videoID: "song")
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: failed.remoteURL.absoluteString
        )
        _ = try await resolve(repository, videoID: "song")
        repository.reportPlaybackCandidateSuccess(
            videoId: "song", streamURL: failed.remoteURL.absoluteString
        )
        repository.reportPlaybackCandidateSuccess(
            videoId: "song", streamURL: "https://media.example.test/unknown.m4a"
        )
        let recovered = try await resolve(repository, videoID: "song")
        XCTAssertTrue(recovered.remoteURL.path.contains("visionOS"))
        repository.reportPlaybackCandidateSuccess(
            videoId: "song", streamURL: recovered.remoteURL.absoluteString
        )

        let fresh = try await resolve(repository, videoID: "song")
        XCTAssertTrue(fresh.remoteURL.path.contains("session"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS", "visionOS", "session"])
    }

    func testExpiredFailuresAndURLsDoNotAffectANewResolution() async throws {
        let api = MediaCandidateAPI()
        let clock = MediaCandidateClock()
        let repository = PlayerRepository(api: api, candidateClock: { clock.now() })
        let failed = try await resolve(repository, videoID: "song")
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: failed.remoteURL.absoluteString
        )
        let fallback = try await resolve(repository, videoID: "song")
        clock.advance(by: 301)
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: fallback.remoteURL.absoluteString
        )

        let fresh = try await resolve(repository, videoID: "song")
        XCTAssertTrue(fresh.remoteURL.path.contains("session"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS", "session"])
    }

    func testCandidateHistoryIsBoundedTo64Videos() async throws {
        let api = MediaCandidateAPI()
        let clock = MediaCandidateClock()
        let repository = PlayerRepository(api: api, candidateClock: { clock.now() })
        let oldest = try await resolve(repository, videoID: "oldest")
        repository.reportPlaybackCandidateFailure(
            videoId: "oldest", streamURL: oldest.remoteURL.absoluteString
        )
        for index in 0..<64 {
            clock.advance(by: 1)
            _ = try await resolve(repository, videoID: "other-\(index)")
        }
        repository.reportPlaybackCandidateFailure(
            videoId: "oldest", streamURL: oldest.remoteURL.absoluteString
        )

        let fresh = try await resolve(repository, videoID: "oldest")
        XCTAssertTrue(fresh.remoteURL.path.contains("session"))
        let calls = await api.calls
        XCTAssertEqual(calls.count, 66)
        XCTAssertTrue(calls.allSatisfy { $0 == "session" })
    }

    func testExplicitSignInRejectionStillStopsFallback() async throws {
        let api = MediaCandidateAPI()
        await api.requireSignIn()
        let repository = PlayerRepository(api: api)
        do {
            _ = try await resolve(repository, videoID: "song")
            XCTFail("Sign-in rejection must be preserved")
        } catch let error as InnerTubeError {
            guard case .videoUnavailable(let reason) = error else {
                return XCTFail("Expected videoUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("LOGIN_REQUIRED"))
        }
        let calls = await api.calls
        XCTAssertEqual(calls, ["session"])
    }

    private func resolve(
        _ repository: PlayerRepository, videoID: String, quality: AudioQuality = .medium
    ) async throws -> StreamDescriptor {
        try await repository.resolveStreamDescriptor(
            videoId: videoID, quality: quality, requestHeaders: [:]
        )
    }
}

private final class MediaCandidateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(seconds)
    }
}

private actor MediaCandidateAPI: PlayerAPIClient {
    private(set) var calls: [String] = []
    private var sessionRevision = 0
    private var signInRequired = false
    private var sessionObserver: (@Sendable () -> Void)?
    private var sessionContinuations: [CheckedContinuation<Void, Never>] = []

    func setSessionRevision(_ revision: Int) { sessionRevision = revision }
    func requireSignIn() { signInRequired = true }

    func suspendSession(onRequest: @escaping @Sendable () -> Void) {
        sessionObserver = onRequest
    }

    func releaseSession() {
        sessionObserver = nil
        let pending = sessionContinuations
        sessionContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data {
        calls.append("session")
        if signInRequired {
            return try JSONSerialization.data(withJSONObject: [
                "playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to verify"]
            ])
        }
        let response = try Self.response(client: "session", videoID: videoId, revision: sessionRevision)
        if let observer = sessionObserver {
            await withCheckedContinuation { continuation in
                sessionContinuations.append(continuation)
                observer()
            }
        }
        return response
    }

    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data {
        calls.append(client.clientName)
        return try Self.response(client: client.clientName, videoID: videoId)
    }

    func playerWithVisionOS(videoId: String) async throws -> Data {
        calls.append("visionOS")
        return try Self.response(client: "visionOS", videoID: videoId)
    }

    func resetSession() async {}

    private static func response(client: String, videoID: String, revision: Int = 0) throws -> Data {
        let qualities = [("low", 139, 48_000), ("medium", 140, 128_000), ("high", 141, 192_000)]
        let formats: [[String: Any]] = qualities.map { quality, itag, bitrate in
            [
                "itag": itag,
                "url": "https://media.example.test/\(videoID)/\(client)-\(revision)-\(quality).m4a",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "bitrate": bitrate,
                "contentLength": "4000000",
                "approxDurationMs": "200000",
                "initRange": ["start": "0", "end": "699"],
                "indexRange": ["start": "700", "end": "1199"],
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "adaptiveFormats": formats,
                "hlsManifestUrl": "https://media.example.test/\(videoID)/short-window.m3u8",
            ],
        ])
    }
}
