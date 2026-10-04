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

    func testOfficialBilingualQuotedTitleFromReportedChartSearchResolves() async throws {
        // Public metadata captured with the same query and API as the shipped homepage.
        let catalog = item(title: "要去什麼地方", artist: "田馥甄")
        let resolved = try await EvanTubeOnlineSongResolver.resolve(catalog) { query in
            XCTAssertEqual(query, "要去什麼地方 田馥甄")
            return [
                self.song("1yBjFEpG3xQ", title: "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe》Official Music Video",
                          artist: "Hebe Tien's Official Channel田馥甄官方專屬頻道"),
                self.song("hlmE_MrxmE4", title: "要去什麼地方", artist: "Hebe Tien - Topic"),
                self.song("fT9BZh4LeO0", title: "田馥甄 Hebe Tien《皆可 Anything Goes》Official Music Video",
                          artist: "Hebe Tien's Official Channel田馥甄官方專屬頻道"),
                self.song("EcAgrp42XuU", title: "田馥甄 - 要去什麼地方 [歌詞字幕版]", artist: "NaturalSelection"),
            ]
        }
        XCTAssertEqual(resolved?.id, "1yBjFEpG3xQ")
        XCTAssertEqual(resolved?.artistName, "田馥甄")
        XCTAssertEqual(resolved?.title, "要去什麼地方")
    }

    func testStructuredTitleKeepsTraditionalSimplifiedEquivalence() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "要去什麼地方", artist: "田馥甄")) { _ in
            [self.song(title: "田馥甄 Hebe Tien〈要去什么地方 The Land of Maybe〉Official Audio")]
        }
        XCTAssertEqual(resolved?.id, "aaaaaaaaaaa")
    }

    func testStructuredLongerChineseTitleCannotMatchShorterCatalogTitle() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "要去什麼地方", artist: "田馥甄")) { _ in
            [self.song(title: "田馥甄 Hebe Tien《要去什麼地方旅行 The Journey》Official Music Video", artist: "田馥甄")]
        }
        XCTAssertNil(resolved)
    }

    func testStructuredEnglishTranslationCannotDiscardRecordingVersion() async throws {
        for version in ["Live", "Cover", "Remix", "Acoustic", "Instrumental"] {
            let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "要去什麼地方", artist: "田馥甄")) { _ in
                [self.song(title: "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe \(version)》Official Audio", artist: "田馥甄")]
            }
            XCTAssertNil(resolved, "A translation must not hide a \(version) recording")
        }
    }

    func testStructuredTitleRejectsUnrelatedSurroundingText() async throws {
        for title in [
            "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe》Album Review",
            "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe》Official Music Video Reaction",
            "田馥甄 Cover Artist《要去什麼地方 The Land of Maybe》Official Audio",
            "Different Artist《要去什麼地方 The Land of Maybe》Official Audio",
        ] {
            let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "要去什麼地方", artist: "田馥甄")) { _ in
                [self.song(title: title, artist: "田馥甄")]
            }
            XCTAssertNil(resolved, title)
        }
    }

    func testStructuredBilingualVideosWithDistinctIDsRemainAmbiguous() async throws {
        let resolved = try await EvanTubeOnlineSongResolver.resolve(item(title: "要去什麼地方", artist: "田馥甄")) { _ in [
            self.song("aaaaaaaaaaa", title: "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe》Official Music Video"),
            self.song("bbbbbbbbbbb", title: "田馥甄 Hebe Tien《要去什麼地方 The Land of Maybe》Official Audio")
        ] }
        XCTAssertNil(resolved, "Bilingual metadata must not override explicit version selection")
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
