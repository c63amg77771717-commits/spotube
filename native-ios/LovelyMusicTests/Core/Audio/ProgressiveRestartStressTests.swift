import Foundation
import XCTest
@testable import LovelyMusic

/// Diagnosis: a progressive stream started right after another one sometimes
/// never became ready (CI, 2026-10-27). Starts eight streams back to back on one
/// engine and prints how long each took to play.
final class ProgressiveRestartStressTests: XCTestCase {
    @MainActor
    func testBackToBackProgressiveStreamsStartPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(Data(contentsOf: generated.url), totalSeconds: 20,
                                                   cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        ProgressiveCDN.prepare(indexed.data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveCDN.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        defer { engine.stop(); session.invalidateAndCancel() }
        let url = "https://progressive-cdn.example.test/videoplayback?id=fixture"
        let total = Int64(indexed.data.count)
        engine.authCookieProvider = { nil }
        engine.streamURLResolver = { _ in (url: url, contentLength: total) }

        var slow: [Int] = []
        for round in 0..<8 {
            let song = Song(id: round % 2 == 0 ? "STRESSAAAAA" : "STRESSBBBBB", title: "Stress \(round)",
                            artistName: "Fixture", artistId: nil, albumName: nil, albumId: nil, duration: 20,
                            thumbnailURL: nil)
            let seek: TimeInterval? = round % 2 == 0 ? nil : 1
            let started = Date()
            engine.play(song: song, seekTo: seek)
            let target = (seek ?? 0) + 0.5
            for _ in 0..<750 where engine.lastError == nil && engine.currentTime < target {
                try await Task.sleep(for: .milliseconds(20))
            }
            let seconds = Date().timeIntervalSince(started)
            print("STRESS round=\(round) seek=\(seek ?? 0) reached=\(engine.currentTime) "
                + "after=\(String(format: "%.2f", seconds))s error=\(engine.lastError ?? "-")")
            if seconds > 6 { slow.append(round) }
        }
        XCTAssertEqual(slow, [], "every stream must start within 6 s")
    }
}
