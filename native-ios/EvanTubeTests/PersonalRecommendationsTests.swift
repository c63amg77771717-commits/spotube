import XCTest
@testable import LovelyMusic

final class PersonalRecommendationsTests: XCTestCase {
    private func song(_ id: String, artist: String = "Artist") -> Song {
        Song(id: id, title: id, artistName: artist, artistId: nil,
             albumName: nil, albumId: nil, duration: 180, thumbnailURL: nil)
    }

    @MainActor func testColdStartUsesRealFallbackWithoutClaimingPersonalization() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PersonalRecommendations(taste: PersonalMusicTaste(defaults: defaults))
        let candidate = song("bbbbbbbbbbb")
        await model.refresh(favorites: [], fallback: [candidate, candidate]) { _ in
            XCTFail("No related requests without listening or favorites")
            return []
        }
        XCTAssertEqual(model.songs.map(\.id), [candidate.id])
        XCTAssertTrue(model.status.contains("目前顯示音源推薦"))
        XCTAssertFalse(model.isLoading)
    }

    @MainActor func testFavoriteSeedsOnlineDiscoveryAndDislikeSurvivesRefresh() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PersonalRecommendations(taste: PersonalMusicTaste(defaults: defaults))
        let seed = song("aaaaaaaaaaa"), candidate = song("bbbbbbbbbbb")
        await model.refresh(favorites: [seed], fallback: []) { id in
            XCTAssertEqual(id, seed.id)
            return [seed, candidate, candidate]
        }
        XCTAssertEqual(model.songs.map(\.id), [candidate.id])
        XCTAssertTrue(model.reasons[candidate.id]?.contains(seed.title) == true)
        model.dislike(candidate)
        XCTAssertTrue(model.songs.isEmpty)
        await model.refresh(favorites: [seed], fallback: [candidate]) { _ in [candidate] }
        XCTAssertTrue(model.songs.isEmpty)
    }

    @MainActor func testSourceFailureFallsBackAndStaleRequestCannotOverwriteNewTaste() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PersonalRecommendations(taste: PersonalMusicTaste(defaults: defaults))
        let a = song("aaaaaaaaaaa"), b = song("bbbbbbbbbbb")
        let c = song("ccccccccccc", artist: "New"), d = song("ddddddddddd", artist: "New")
        await model.refresh(favorites: [a], fallback: [b]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(model.songs.map(\.id), [b.id])
        XCTAssertTrue(model.status.contains("暫時無法取得"))
        var oldStarted = false
        let old = Task {
            await model.refresh(favorites: [a], fallback: [], force: true) { _ in
                oldStarted = true
                try? await Task.sleep(for: .milliseconds(100))
                return [b]
            }
        }
        while !oldStarted { await Task.yield() }
        await model.refresh(favorites: [c], fallback: [], force: true) { _ in [d] }
        await old.value
        XCTAssertEqual(model.songs.map(\.id), [d.id])
    }
}
