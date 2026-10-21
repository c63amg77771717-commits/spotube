import Foundation
import XCTest
@testable import LovelyMusic

/// Build36: reproduces the background-next failure boundary without
/// authenticating or talking to YouTube/Google Drive.
final class BackgroundNextAndTransferDiagnosticsTests: XCTestCase {
    func testLockScreenUnavailableTrackDoesNotWaitForForegroundSourcePicker() {
        for category: PlaybackErrorCategory in [.unknown, .songRemoved, .regionBlocked] {
            XCTAssertFalse(PlaybackUnavailablePolicy.offersManualReplacement(
                category: category, isPermanent: true, hasSearcher: true,
                appIsActive: false
            ), "A lock-screen user cannot select a replacement")
            XCTAssertTrue(PlaybackUnavailablePolicy.offersManualReplacement(
                category: category, isPermanent: true, hasSearcher: true,
                appIsActive: true
            ), "A foreground user may still manually replace this source")
        }
        XCTAssertFalse(PlaybackUnavailablePolicy.offersManualReplacement(
            category: .authRequired, isPermanent: true, hasSearcher: true,
            appIsActive: false
        ), "Background mode never bypasses authentication")
        XCTAssertFalse(PlaybackUnavailablePolicy.offersManualReplacement(
            category: .unknown, isPermanent: false, hasSearcher: true,
            appIsActive: true
        ), "Transient playback failures must still use bounded recovery")
        XCTAssertFalse(PlaybackUnavailablePolicy.offersManualReplacement(
            category: .unknown, isPermanent: true, hasSearcher: false,
            appIsActive: true
        ))
    }

    func testSignedCDNURLIsRefreshedOnlyAfterRealHTTPRejection() {
        for status in [200, 206, 302, 400, 416, 500, 503] {
            XCTAssertFalse(SignedAudioURLRefreshPolicy.shouldRefresh(
                httpStatus: status, retry: 0
            ))
        }
        XCTAssertFalse(SignedAudioURLRefreshPolicy.shouldRefresh(
            httpStatus: nil, retry: 0
        ))
        for status in [403, 410, 429] {
            XCTAssertTrue(SignedAudioURLRefreshPolicy.shouldRefresh(
                httpStatus: status, retry: 0
            ))
            XCTAssertFalse(SignedAudioURLRefreshPolicy.shouldRefresh(
                httpStatus: status, retry: 1
            ), "At most one URL refresh for a rejected segment")
        }
    }

    func testIntegrityFailureKindsRemainAllowlisted() {
        XCTAssertEqual(AudioTransferIntegrityError.invalidResponse.diagnosticFailure, .invalidResponse)
        XCTAssertEqual(AudioTransferIntegrityError.incompleteResource.diagnosticFailure, .incompleteResource)
        XCTAssertEqual(AudioTransferIntegrityError.resourceChanged.diagnosticFailure, .resourceChanged)
        XCTAssertEqual(AudioTransferIntegrityError.invalidIndex.diagnosticFailure, .invalidIndex)
        XCTAssertEqual(AudioTransferIntegrityError.durationMismatch.diagnosticFailure, .durationMismatch)
    }

    func testTransferFailureAndRemoteNextSurviveExportWithoutSecrets() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("build36-diagnostics-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlaybackDiagnostics(fileURL: file)
        store.record(.init(phase: .remoteNext, videoID: "zxiIp8Wexps",
            shuffleEnabled: true, queueCount: 995, currentIndex: 715))
        store.record(.init(phase: .transferFailure, videoID: "zxiIp8Wexps",
            httpStatus: 206, transportErrorCode: -1001,
            transferStage: .segmentRange, transferFailure: .resourceChanged))
        XCTAssertEqual(store.events.count, 2)
        let report = try store.reportData()
        let decoded = try JSONSerialization.jsonObject(with: report) as? [String: Any]
        let events = try XCTUnwrap(decoded?["events"] as? [[String: Any]])
        XCTAssertEqual(events[0]["phase"] as? String, "remoteNext")
        XCTAssertEqual(events[1]["phase"] as? String, "transferFailure")
        XCTAssertEqual(events[1]["transferStage"] as? String, "segmentRange")
        XCTAssertEqual(events[1]["transferFailure"] as? String, "resourceChanged")
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("https://"))
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("Authorization"))
        let restored = PlaybackDiagnostics(fileURL: file)
        XCTAssertEqual(restored.events.last?.transferFailure, .resourceChanged)
        XCTAssertEqual(restored.events.last?.transferStage, .segmentRange)
    }
}
