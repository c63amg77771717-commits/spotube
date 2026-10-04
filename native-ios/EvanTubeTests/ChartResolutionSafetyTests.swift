import XCTest
@testable import LovelyMusic

final class ChartResolutionSafetyTests: XCTestCase {
    private func item(title: String = "Fixture Track", artist: String = "Fixture Artist") -> EvanTubeOnlineItem {
        EvanTubeOnlineItem(id: "1234567890", title: title, artist: artist,
                          artworkURL: nil, kind: .song, releaseDate: nil)
    }

    private func song(_ id: String = "aaaaaaaaaaa", title: String, artist: String = "Record Label") -> Song {
        Song(id: id, title: title, artistName: artist, artistId: nil,
             albumName: nil, albumId: nil, duration: nil, thumbnailURL: nil)
    }

    func testFeaturedArtistCreditMatchesWhenVideoUsesFtRatherThanCatalogFeat() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "Fixture Track (feat. Guest Artist)")) { _ in
            [self.song(title: "Fixture Artist - Fixture Track ft. Guest Artist (Official Video)")]
        }
        XCTAssertEqual(resolved?.id, "aaaaaaaaaaa")
        XCTAssertEqual(resolved?.title, "Fixture Track (feat. Guest Artist)")
    }

    func testFeaturedArtistCreditDoesNotAcceptADifferentGuest() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "Fixture Track (feat. Guest Artist)")) { _ in
            [self.song(title: "Fixture Artist - Fixture Track ft. Different Guest (Official Video)")]
        }
        XCTAssertNil(resolved, "Removing featured credits entirely can select a different recording")
    }

    func testAmbiguousDistinctVideoIDsRequireUserSelectionInsteadOfFirstResult() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item()) { _ in [
            self.song("aaaaaaaaaaa", title: "Fixture Artist - Fixture Track (Official Video)"),
            self.song("bbbbbbbbbbb", title: "Fixture Artist - Fixture Track (Official Audio)")
        ] }
        XCTAssertNil(resolved, "Search ordering is not evidence for choosing between two matching versions")
    }

    func testDuplicateSearchRowsForSameVideoAreNotAmbiguous() async throws {
        let candidate = song(title: "Fixture Artist - Fixture Track (Official Video)")
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item()) { _ in [candidate, candidate] }
        XCTAssertEqual(resolved?.id, "aaaaaaaaaaa")
    }

    func testLongerDifferentSongTitleDoesNotMatchShortCatalogTitle() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "Stay")) { _ in
            [self.song(title: "Fixture Artist - Stay With Me (Official Video)")]
        }
        XCTAssertNil(resolved, "Substring evidence must not start an unrelated song")
    }

    func testCancellationDuringSearchCannotReturnPlayableSong() async throws {
        let candidate = song(title: "Fixture Artist - Fixture Track (Official Video)")
        let catalogItem = item()
        let task = Task {
            try await EvanTubeOnlineSongResolver.resolve(catalogItem) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [candidate]
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate even if the search dependency returns a result")
        } catch is CancellationError {
            // Expected: no playable result escapes a cancelled resolution.
        }
    }

    func testWrongArtistStillRequiresExplicitSearchRatherThanUnrelatedFallback() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item()) { _ in
            [self.song(title: "Different Artist - Fixture Track (Official Video)")]
        }
        XCTAssertNil(resolved)
    }

    func testArtistTokenInsideSongTitleIsNotArtistEvidence() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "Killer Queen", artist: "Queen")) { _ in
            [self.song(title: "Killer Queen (Official Video)", artist: "Different Artist")]
        }
        XCTAssertNil(resolved, "An artist word occurring in the recording title does not identify the performer")
    }

    @MainActor func testFailedRefreshKeepsPreviouslyLoadedFeedsVisible() async {
        let feeds = EvanTubeHomeFeeds()
        let cached = EvanTubeOnlineFeed(sourceName: "cached chart", updatedAt: nil, periodStart: nil, items: [item()])
        feeds.chart = cached
        feeds.weekly = cached
        feeds.releases = cached
        await feeds.refresh(region: "TW", loadChart: { _ in throw URLError(.notConnectedToInternet) },
                            loadWeekly: { throw URLError(.notConnectedToInternet) },
                            loadReleases: { throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(feeds.chart?.items.first?.id, "1234567890")
        XCTAssertEqual(feeds.weekly?.items.first?.id, "1234567890")
        XCTAssertEqual(feeds.releases?.items.first?.id, "1234567890")
        XCTAssertNotNil(feeds.chartError)
        XCTAssertFalse(feeds.isLoading)
    }
}
