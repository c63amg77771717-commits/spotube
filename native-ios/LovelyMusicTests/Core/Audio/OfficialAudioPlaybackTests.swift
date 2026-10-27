import Foundation
import XCTest
@testable import LovelyMusic

/// Audio mode plays YouTube Music's official audio of a video; turning video
/// mode on mid-song switches the sound back to the video's own recording.
final class OfficialAudioPlaybackTests: XCTestCase {
    @MainActor
    final class Requests {
        var ids: [String] = []
    }

    @MainActor
    func testAudioModePlaysOfficialAudioAndVideoModeSwitchesBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(Data(contentsOf: generated.url), totalSeconds: 20,
                                                   cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        ProgressiveCDN.prepare(indexed.data)

        let suite = "OfficialAudioPlaybackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let official = OfficialAudioCatalog.Match(videoID: "OFFICIALATV", title: "Progressive Start",
                                                  artist: "Fixture", duration: 20)
        let catalog = OfficialAudioCatalog(search: { _ in [official] }, defaults: defaults)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveCDN.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        defer { engine.stop(); session.invalidateAndCancel() }
        let url = "https://progressive-cdn.example.test/videoplayback?id=fixture"
        let total = Int64(indexed.data.count)
        let requests = Requests()
        engine.authCookieProvider = { nil }
        engine.officialAudio = catalog
        engine.playlistSourceIDResolver = { catalog.sourceID(for: $0.id) }   // as DIContainer wires it
        engine.contextualStreamURLResolver = { song in
            requests.ids.append(catalog.sourceID(for: song.id))
            return (url: url, contentLength: total)
        }
        let song = Song(id: "PROGSTART01", title: "Fixture - Progressive Start (Official Music Video)",
                        artistName: "Fixture", artistId: nil, albumName: nil, albumId: nil, duration: 21,
                        thumbnailURL: nil)

        engine.play(song: song)
        try await waitUntil { engine.lastError != nil || engine.currentTime >= 1 }
        XCTAssertNil(engine.lastError)
        XCTAssertGreaterThanOrEqual(engine.currentTime, 1, "the official audio must start playing")
        // The progressive stream asks again for a fresh URL every few ranges.
        XCTAssertEqual(Set(requests.ids), ["OFFICIALATV"])
        XCTAssertEqual(engine.playbackSourceID(for: song), "OFFICIALATV")

        let beforeSwitch = requests.ids.count
        engine.setVideoMode(true)
        XCTAssertEqual(engine.playbackSourceID(for: song), "PROGSTART01")
        try await waitUntil {
            engine.lastError != nil || (requests.ids.count > beforeSwitch && engine.currentTime >= 2)
        }
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(Set(requests.ids[beforeSwitch...]), ["PROGSTART01"], "video mode plays the video's own sound")
        XCTAssertGreaterThanOrEqual(engine.currentTime, 2, "the switch keeps the position and keeps playing")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<750 where !condition() {   // 15 s
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
