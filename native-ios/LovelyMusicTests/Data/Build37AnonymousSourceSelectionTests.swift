import Foundation
import XCTest

@testable import LovelyMusic

/// Session-aware source selection, using descriptors only. The separate
/// playback integration test verifies that the selected media actually plays.
final class Build37AnonymousSourceSelectionTests: XCTestCase {
    func testAnonymousIOS200CannotHideFullVisionOSAudio() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        let repository = PlayerRepository(api: api)

        let descriptor = try await resolve(repository)

        XCTAssertTrue(descriptor.remoteURL.path.contains("visionOS-0"))
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        XCTAssertEqual(descriptor.duration, .seconds(240))
        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS"], "A valid guest iOS descriptor must not win by being first")
    }

    func testAnonymousShortHLSWaitsForFullPublicWebAudio() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        await api.setReply(.shortHLS, for: "visionOS")

        let descriptor = try await resolve(PlayerRepository(api: api))

        XCTAssertTrue(descriptor.remoteURL.path.contains("WEB_REMIX-0"))
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS", "WEB_REMIX"])
    }

    func testAnonymousGuestIOSIsOnlyLastCompatibilitySource() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        await api.setReply(.unavailable, for: "visionOS")
        await api.setReply(.unavailable, for: "WEB_REMIX")

        let descriptor = try await resolve(PlayerRepository(api: api))

        XCTAssertTrue(descriptor.remoteURL.path.contains("session-0"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS", "WEB_REMIX", "session"])
    }

    func testAuthenticatedSessionRetainsFirstChoice() async throws {
        let api = Build37SourceAPI(isAuthenticated: true)

        let descriptor = try await resolve(PlayerRepository(api: api))

        XCTAssertTrue(descriptor.remoteURL.path.contains("session-0"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session"])
    }

    func testAuthenticatedIOSHTTP400StillFallsBackToVisionOS() async throws {
        let api = Build37SourceAPI(isAuthenticated: true)
        await api.setReply(.httpFailure, for: "session")

        let descriptor = try await resolve(PlayerRepository(api: api))

        XCTAssertTrue(descriptor.remoteURL.path.contains("visionOS-0"))
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS"])
    }

    func testAnonymousFailedCandidatesDoNotLoopBackToGuestIOS() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        let repository = PlayerRepository(api: api)
        for client in ["visionOS", "WEB_REMIX", "session"] {
            let descriptor = try await resolve(repository)
            XCTAssertTrue(descriptor.remoteURL.path.contains("\(client)-0"))
            repository.reportPlaybackCandidateFailure(
                videoId: "song", streamURL: descriptor.remoteURL.absoluteString
            )
        }

        for _ in 0..<3 {
            do {
                _ = try await resolve(repository)
                XCTFail("All anonymous candidates were already rejected")
            } catch let error as InnerTubeError {
                guard case .noStreamAvailable = error else {
                    return XCTFail("Unexpected exhausted-source error: \(error)")
                }
            }
        }
        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS", "WEB_REMIX", "session"])
    }

    func testCandidateRejectionsAndOldURLsDoNotCrossAuthenticationChanges() async throws {
        let api = Build37SourceAPI(isAuthenticated: true)
        let repository = PlayerRepository(api: api)
        let signedSession = try await resolve(repository)
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: signedSession.remoteURL.absoluteString
        )
        let signedVision = try await resolve(repository)
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: signedVision.remoteURL.absoluteString
        )

        await api.changeAuthentication(to: false)
        let guestVision = try await resolve(repository)
        XCTAssertTrue(guestVision.remoteURL.path.contains("visionOS-1"),
                      "The signed-in VisionOS rejection must not affect a guest session")
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: signedVision.remoteURL.absoluteString
        )
        let guestRetry = try await resolve(repository)
        XCTAssertEqual(guestRetry.remoteURL, guestVision.remoteURL,
                       "An old account's URL must not reject the new guest candidate")
        repository.reportPlaybackCandidateFailure(
            videoId: "song", streamURL: guestVision.remoteURL.absoluteString
        )
        let guestWeb = try await resolve(repository)
        XCTAssertTrue(guestWeb.remoteURL.path.contains("WEB_REMIX-1"))

        await api.changeAuthentication(to: true)
        let signedAgain = try await resolve(repository)
        XCTAssertTrue(signedAgain.remoteURL.path.contains("session-2"),
                      "Signing in again must not reuse old account exclusions")
        let calls = await api.calls
        XCTAssertEqual(calls, ["session", "visionOS", "visionOS", "visionOS", "WEB_REMIX", "session"])
    }

    func testLoginDoesNotJoinPendingAnonymousResolution() async throws {
        try await assertAuthenticationTransition(initiallyAuthenticated: false, nextAuthenticated: true)
    }

    func testLogoutDoesNotJoinPendingAuthenticatedResolution() async throws {
        try await assertAuthenticationTransition(initiallyAuthenticated: true, nextAuthenticated: false)
    }

    func testAccountSwitchDoesNotJoinAnotherAuthenticatedGeneration() async throws {
        try await assertAuthenticationTransition(initiallyAuthenticated: true, nextAuthenticated: true)
    }

    func testLogoutDiscardsOldSuccessfulResultWithoutANewPlaybackRequest() async throws {
        let api = Build37SourceAPI(isAuthenticated: true)
        let repository = PlayerRepository(api: api)
        let oldStarted = expectation(description: "old account request parked")
        await api.suspendNext("session") { oldStarted.fulfill() }
        let oldRequest = Task {
            try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .medium, requestHeaders: [:]
            )
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        await api.changeAuthentication(to: false)
        await api.releaseSuspensions()

        do {
            _ = try await oldRequest.value
            XCTFail("A signed-in URL must never be returned after logout")
        } catch is CancellationError {
            // The obsolete result is deliberately discarded.
        }
        let calls = await api.calls
        XCTAssertEqual(calls, ["session"])
    }

    func testAnonymousVisionOSSignInRequirementStopsOtherClients() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        await api.setReply(.signInRequired, for: "visionOS")

        try await assertSignInRequired(PlayerRepository(api: api))

        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS"])
    }

    func testAnonymousWebSignInRequirementDoesNotFallThroughToGuestIOS() async throws {
        let api = Build37SourceAPI(isAuthenticated: false)
        await api.setReply(.unavailable, for: "visionOS")
        await api.setReply(.signInRequired, for: "WEB_REMIX")

        try await assertSignInRequired(PlayerRepository(api: api))

        let calls = await api.calls
        XCTAssertEqual(calls, ["visionOS", "WEB_REMIX"])
    }

    private func assertAuthenticationTransition(
        initiallyAuthenticated: Bool, nextAuthenticated: Bool
    ) async throws {
        let api = Build37SourceAPI(isAuthenticated: initiallyAuthenticated)
        let repository = PlayerRepository(api: api)
        let oldClient = initiallyAuthenticated ? "session" : "visionOS"
        let nextClient = nextAuthenticated ? "session" : "visionOS"
        let oldStarted = expectation(description: "old session resolution parked")
        await api.suspendNext(oldClient) { oldStarted.fulfill() }
        let oldRequest = Task {
            try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .medium, requestHeaders: [:]
            )
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        await api.changeAuthentication(to: nextAuthenticated)
        let newFinished = expectation(description: "new session completes independently")
        let newRequest = Task {
            defer { newFinished.fulfill() }
            return try await repository.resolveStreamDescriptor(
                videoId: "song", quality: .medium, requestHeaders: ["X-Test": "new-session"]
            )
        }
        await fulfillment(of: [newFinished], timeout: 2)
        // Always release the old request, even if isolation regresses.
        await api.releaseSuspensions()
        let current = try await newRequest.value
        XCTAssertTrue(current.remoteURL.path.contains("\(nextClient)-1"))
        XCTAssertEqual(current.requestHeaders["X-Test"], "new-session")
        do {
            _ = try await oldRequest.value
            XCTFail("A successful descriptor from an obsolete session must be discarded")
        } catch is CancellationError {
            // Expected even though the old HTTP descriptor itself was valid.
        }
        let calls = await api.calls
        XCTAssertEqual(calls, [oldClient, nextClient])
    }

    private func assertSignInRequired(_ repository: PlayerRepository) async throws {
        do {
            _ = try await resolve(repository)
            XCTFail("Explicit sign-in restrictions must remain authoritative")
        } catch let error as InnerTubeError {
            guard case .videoUnavailable(let reason) = error else {
                return XCTFail("Unexpected playability error: \(error)")
            }
            XCTAssertTrue(reason.contains("LOGIN_REQUIRED"))
        }
    }

    private func resolve(_ repository: PlayerRepository) async throws -> StreamDescriptor {
        try await repository.resolveStreamDescriptor(
            videoId: "song", quality: .medium, requestHeaders: [:]
        )
    }
}

private actor Build37SourceAPI: PlayerAPIClient {
    enum Reply: Sendable {
        case fullAudio, shortHLS, unavailable, signInRequired, httpFailure
    }

    private(set) var calls: [String] = []
    private var context: PlayerSessionContext
    private var replies: [String: Reply] = [:]
    private var suspendedClient: String?
    private var onSuspend: (@Sendable () -> Void)?
    private var suspended: [CheckedContinuation<Void, Never>] = []

    init(isAuthenticated: Bool) {
        context = PlayerSessionContext(isAuthenticated: isAuthenticated, generation: 0)
    }

    func playerSessionContext() async -> PlayerSessionContext { context }

    func changeAuthentication(to authenticated: Bool) {
        context = PlayerSessionContext(isAuthenticated: authenticated, generation: context.generation &+ 1)
    }

    func setReply(_ reply: Reply, for client: String) { replies[client] = reply }

    func suspendNext(_ client: String, onSuspend: @escaping @Sendable () -> Void) {
        suspendedClient = client
        self.onSuspend = onSuspend
    }

    func releaseSuspensions() {
        let pending = suspended
        suspended.removeAll()
        pending.forEach { $0.resume() }
    }

    func playerWithSession(videoId: String, playlistId: String?) async throws -> Data {
        try await response(for: "session", videoID: videoId)
    }

    func playerWithVisionOS(videoId: String) async throws -> Data {
        try await response(for: "visionOS", videoID: videoId)
    }

    func player(client: YouTubeClient, videoId: String, playlistId: String?) async throws -> Data {
        try await response(for: client.clientName, videoID: videoId)
    }

    func resetSession() async {}

    private func response(for client: String, videoID: String) async throws -> Data {
        calls.append(client)
        let payload = try Self.payload(
            reply: replies[client] ?? .fullAudio, client: client,
            videoID: videoID, generation: context.generation
        )
        if suspendedClient == client {
            suspendedClient = nil
            let observer = onSuspend
            onSuspend = nil
            await withCheckedContinuation { continuation in
                suspended.append(continuation)
                observer?()
            }
        }
        return payload
    }

    private static func payload(
        reply: Reply, client: String, videoID: String, generation: UInt64
    ) throws -> Data {
        let body: [String: Any]
        switch reply {
        case .httpFailure:
            throw InnerTubeError.httpError(statusCode: 400)
        case .signInRequired:
            body = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to verify"]]
        case .unavailable:
            body = ["playabilityStatus": ["status": "UNPLAYABLE", "reason": "Unavailable fixture"]]
        case .shortHLS:
            body = [
                "playabilityStatus": ["status": "OK"],
                "streamingData": [
                    "hlsManifestUrl": "https://media.example.test/short-window.m3u8",
                    "adaptiveFormats": [],
                ],
            ]
        case .fullAudio:
            body = [
                "playabilityStatus": ["status": "OK"],
                "streamingData": [
                    "hlsManifestUrl": "https://media.example.test/short-window.m3u8",
                    "adaptiveFormats": [[
                        "itag": 140,
                        "url": "https://media.example.test/\(videoID)/\(client)-\(generation).m4a",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 128_000,
                        "contentLength": "3000000",
                        "approxDurationMs": "240000",
                    ]],
                ],
            ]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
