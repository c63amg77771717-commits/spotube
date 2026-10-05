import AVFoundation
import UIKit
import XCTest
@testable import LovelyMusic

@MainActor
final class AudioCachePlaybackProtectionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(_ directory: URL, _ id: String, bytes: Int = 80) throws -> URL {
        let url = directory.appendingPathComponent(id + "_remuxed.m4a")
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testLRUEvictsAnUnusedFileAndMakesReleasedPlaybackEligibleAgain() throws {
        let dir = try directory()
        let cache = AudioCacheManager(maxCacheSize: 100, directory: dir)
        let active = try file(dir, "active00001")
        cache.registerFile(videoId: "active00001", fileURL: active)
        cache.setPlaybackProtectedFiles([active])
        let unused = try file(dir, "unused00001")
        cache.registerFile(videoId: "unused00001", fileURL: unused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        cache.setPlaybackProtectedFiles([])
        let replacement = try file(dir, "replacement")
        cache.registerFile(videoId: "replacement", fileURL: replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testBackgroundSweepKeepsActiveSupersededAndUnregisteredPlaybackFiles() throws {
        let dir = try directory()
        let cache = AudioCacheManager(directory: dir)
        let active = try file(dir, "active00001")
        cache.registerFile(videoId: "active00001", fileURL: active)
        let inFlight = try file(dir, "inflight001")
        let orphan = try file(dir, "orphan00001")
        cache.setPlaybackProtectedFiles([active, inFlight])
        cache.trimToFit()
        cache.removeOrphans(knownDownloadIds: ["active00001"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        cache.setPlaybackProtectedFiles([])
        cache.removeOrphans(knownDownloadIds: ["active00001"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inFlight.path))
    }

    func testMemoryWarningDoesNotDeleteTheActivePlaybackFile() throws {
        let dir = try directory()
        let cache = AudioCacheManager(maxCacheSize: 100, directory: dir)
        let active = try file(dir, "active00001")
        cache.registerFile(videoId: "active00001", fileURL: active)
        cache.setPlaybackProtectedFiles([active])
        let unused = try file(dir, "unused00001", bytes: 10)
        cache.registerFile(videoId: "unused00001", fileURL: unused)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }

    func testAudioEngineProtectsItsSelectedFileUntilStopReleasesIt() throws {
        let dir = try directory()
        let source = try XCTUnwrap(Bundle.main.url(forResource: "demo_song_morning_light", withExtension: "m4a"))
        let active = dir.appendingPathComponent("active00001_remuxed.m4a")
        try FileManager.default.copyItem(at: source, to: active)
        let cache = AudioCacheManager(directory: dir)
        cache.registerFile(videoId: "active00001", fileURL: active)
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.audioCacheManager = cache
        var song = Song(id: "active00001", title: "Fixture", artistName: "Fixture", artistId: nil,
                        albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
        song.streamURL = active.absoluteString
        engine.play(song: song)
        cache.removeOrphans(knownDownloadIds: [song.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        engine.stop()
        cache.removeOrphans(knownDownloadIds: [song.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }
}
