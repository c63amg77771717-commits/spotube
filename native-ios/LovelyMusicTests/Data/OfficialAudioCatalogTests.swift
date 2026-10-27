import Foundation
import XCTest
@testable import LovelyMusic

final class OfficialAudioCatalogTests: XCTestCase {
    private typealias Match = OfficialAudioCatalog.Match
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let name = "OfficialAudioCatalogTests-\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func song(_ id: String, _ title: String, duration: Int = 282) -> Song {
        Song(id: id, title: title, artistName: "", artistId: nil, albumName: nil, albumId: nil,
             duration: duration, thumbnailURL: nil)
    }

    func testSongSearchRowsParse() throws {
        let json = #"""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":[
          {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"bGRFDm7pW50"},
            "flexColumns":[
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"遇見"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"孫燕姿"},{"text":" • "},{"text":"The Moment"},{"text":" • "},{"text":"3:30"}]}}}]}},
          {"musicResponsiveListItemRenderer":{"overlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"qUseO9jOJD4"}}}}}},
            "flexColumns":[
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"開始懂了"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"孫燕姿 • 我要的幸福 • 1:04:32"}]}}}]}},
          {"musicResponsiveListItemRenderer":{"flexColumns":[]}}
        ]}}]}}}}]}}}
        """#
        let response = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(YouTubeMusicLyricsService.songResults(response), [
            Match(videoID: "bGRFDm7pW50", title: "遇見", artist: "孫燕姿", duration: 210),
            Match(videoID: "qUseO9jOJD4", title: "開始懂了", artist: "孫燕姿", duration: 3872),
        ])
    }

    func testFindPicksTheSameSongAndSkipsOtherVersions() async {
        let queries = LockedIDs()
        let results = [
            Match(videoID: "COVER000001", title: "可以不可以", artist: "某翻唱", duration: 280),
            Match(videoID: "LIVE0000001", title: "可以不可以 (Live)", artist: "丁噹", duration: 300),
            Match(videoID: "OFFICIAL001", title: "可以不可以", artist: "丁當", duration: 282),
        ]
        let found = await OfficialAudioCatalog.find(title: "丁噹 - 可以不可以【動態歌詞】", duration: 285) { query in
            queries.append(query)
            return results
        }
        XCTAssertEqual(found?.videoID, "OFFICIAL001")
        XCTAssertEqual(queries.values, ["可以不可以 丁噹"])
        let none = await OfficialAudioCatalog.find(title: "丁噹 - 可以不可以 (Cover by 某人)", duration: 285) { _ in
            [Match(videoID: "OFFICIAL001", title: "可以不可以", artist: "其他歌手", duration: 282)]
        }
        XCTAssertNil(none)
    }

    @MainActor
    func testSubstitutionFollowsModeDownloadsAndRejection() async throws {
        let store = try defaults()
        let match = Match(videoID: "OFFICIAL001", title: "可以不可以", artist: "丁當", duration: 282)
        let catalog = OfficialAudioCatalog(search: { _ in [match] }, defaults: store)
        let video = song("fYZhA9-bFv8", "丁噹 - 可以不可以")
        XCTAssertTrue(catalog.needsLookup(video))
        await catalog.prepare(video)
        XCTAssertFalse(catalog.needsLookup(video))
        XCTAssertEqual(catalog.sourceID(for: video.id), "OFFICIAL001")

        catalog.isEnabled = false                                   // video mode
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id)
        catalog.isEnabled = true

        catalog.keepsOriginal = { $0 == video.id }                  // downloaded file
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id)
        catalog.keepsOriginal = { _ in false }

        // Saved for the next launch.
        let relaunched = OfficialAudioCatalog(search: { _ in [] }, defaults: store)
        XCTAssertEqual(relaunched.sourceID(for: video.id), "OFFICIAL001")

        catalog.reject(video.id)
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id)
        XCTAssertEqual(OfficialAudioCatalog(search: { _ in [] }, defaults: store).sourceID(for: video.id), video.id)
    }

    @MainActor
    func testTransportFailureIsRetriedInsteadOfPinned() async throws {
        let catalog = OfficialAudioCatalog(search: { _ in throw URLError(.cannotConnectToHost) },
                                           defaults: try defaults(), timeout: .seconds(2))
        let video = song("XXXXXXXXXXX", "沒有這首歌 - 不存在")
        await catalog.prepare(video)
        XCTAssertTrue(catalog.needsLookup(video), "a transport failure must not be cached as a miss")
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id)
    }

    @MainActor
    func testOfficialTracksAndUnknownSongsAreLeftAlone() async throws {
        let catalog = OfficialAudioCatalog(search: { _ in [] }, defaults: try defaults())
        var atv = song("bGRFDm7pW50", "遇見")
        atv.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        XCTAssertFalse(catalog.needsLookup(atv))
        XCTAssertFalse(catalog.needsLookup(song("local-file-1", "Local")))
        let unknown = song("XXXXXXXXXXX", "沒有這首歌 - 不存在")
        await catalog.prepare(unknown)
        XCTAssertFalse(catalog.needsLookup(unknown), "a miss is remembered for this run")
        XCTAssertEqual(catalog.sourceID(for: unknown.id), unknown.id)
    }

    @MainActor
    func testSlowSearchKeepsTheVideoNowAndServesTheNextLaunch() async throws {
        let store = try defaults()
        let match = Match(videoID: "OFFICIAL001", title: "可以不可以", artist: "丁當", duration: 282)
        let catalog = OfficialAudioCatalog(search: { _ in
            try await Task.sleep(for: .milliseconds(600))
            return [match]
        }, defaults: store, timeout: .milliseconds(100))
        let video = song("fYZhA9-bFv8", "丁噹 - 可以不可以")
        let started = Date()
        await catalog.prepare(video)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "playback must not wait for a slow search")
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id, "this run keeps the video once it started")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(catalog.sourceID(for: video.id), video.id)
        XCTAssertEqual(OfficialAudioCatalog(search: { _ in [] }, defaults: store).sourceID(for: video.id), "OFFICIAL001")
    }

    func testLyricsFollowTheOfficialAudio() async throws {
        let match = Match(videoID: "OFFICIAL001", title: "可以不可以", artist: "丁當", duration: 281)
        let catalog = OfficialAudioCatalog(search: { _ in [match] }, defaults: try defaults())
        let asked = LockedIDs()
        let repository = YouTubeMusicFirstLyricsRepository(official: { id in
            asked.append(id)
            return SyncedLyrics(lines: [LyricLine(time: 1, text: "第一句")], source: "YouTube Music",
                                providerID: .youtubeMusic)
        }, fallbacks: [], officialAudio: catalog)
        let context = LyricsLookupContext(songID: "fYZhA9-bFv8", title: "丁噹 - 可以不可以", artist: "",
                                          duration: 285, hasYouTubeOrigin: true)
        let report = try await repository.lookup(context: context)
        XCTAssertEqual(report.state, .synchronized)
        XCTAssertEqual(asked.values, ["OFFICIAL001"])

        catalog.isEnabled = false
        _ = try await repository.lookup(context: context)
        XCTAssertEqual(asked.values, ["OFFICIAL001", "fYZhA9-bFv8"], "video mode keeps the video's lyrics")
    }
}

private final class LockedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.withLock { ids.append(id) } }
    var values: [String] { lock.withLock { ids } }
}
