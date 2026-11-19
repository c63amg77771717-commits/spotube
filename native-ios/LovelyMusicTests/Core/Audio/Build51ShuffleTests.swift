import XCTest
@testable import LovelyMusic

/// Artist-separated shuffle. A uniform Fisher-Yates leaves an artist-grouped
/// playlist in runs; these cases fail if the same artist is still blocked together.
final class Build51ShuffleTests: XCTestCase {
    func testGroupedArtistsAreSpreadSoNobodyPlaysInABlock() {
        let artists = ["A", "B", "C", "D"]
        let songs = artists.flatMap { artist in (0..<6).map { "\(artist)-\($0)" } }
        for seed in UInt64(1)...40 {
            var generator = Build51Generator(state: seed)
            let order = ArtistSeparatedShuffle.order(Array(songs.indices), artistKey: { String(songs[$0].prefix(1)) }, using: &generator)
            XCTAssertEqual(Set(order), Set(songs.indices))
            XCTAssertEqual(order.count, songs.count)
            XCTAssertEqual(longestRun(order.map { songs[$0].prefix(1) }), 1, "seed \(seed) still clusters an artist")
        }
    }

    func testCurrentSongStaysFirstAndTheNextArtistChanges() {
        let songs = (0..<6).map { "A-\($0)" } + (0..<6).map { "B-\($0)" } + (0..<6).map { "C-\($0)" }
        for seed in UInt64(1)...40 {
            var generator = Build51Generator(state: seed)
            let order = ArtistSeparatedShuffle.order(
                Array(songs.indices),
                artistKey: { String(songs[$0].prefix(1)) },
                pinning: 0,
                using: &generator
            )
            XCTAssertEqual(order.first, 0)
            XCTAssertEqual(Set(order).count, songs.count)
            XCTAssertNotEqual(String(songs[order[1]].prefix(1)), "A")
            XCTAssertEqual(longestRun(order.map { String(songs[$0].prefix(1)) }), 1, "seed \(seed)")
        }
    }

    func testDominantArtistIsSplitInsteadOfLeftAsABlock() {
        let songs = (0..<7).map { _ in "A" } + ["B", "C", "D"]
        for seed in UInt64(1)...40 {
            var generator = Build51Generator(state: seed)
            let order = ArtistSeparatedShuffle.order(Array(songs.indices), artistKey: { songs[$0] }, using: &generator)
            XCTAssertEqual(Set(order), Set(songs.indices))
            XCTAssertLessThanOrEqual(longestRun(order.map { songs[$0] }), 2, "seed \(seed)")
        }
    }

    func testSameArtistIdStaysOneArtistEvenWhenTheDisplayNameDiffers() {
        let keys = ["id:shared", "id:shared", "id:shared", "id:shared", "id:shared", "id:other"]
        var generator = Build51Generator(state: 7)
        let order = ArtistSeparatedShuffle.order(Array(keys.indices), artistKey: { keys[$0] }, using: &generator)
        let sequence = order.map { keys[$0] }
        XCTAssertGreaterThan(longestRun(sequence), 1, "five songs by one artist in a six-song queue have to sit together somewhere")
        XCTAssertLessThanOrEqual(longestRun(sequence), 3)
    }

    func testBlankArtistNamesDoNotCollapseIntoOneCluster() {
        let keys = ["song:1", "song:2", "song:3", "song:4", "name:b", "name:b", "name:b", "name:b"]
        for seed in UInt64(1)...20 {
            var generator = Build51Generator(state: seed)
            let order = ArtistSeparatedShuffle.order(Array(keys.indices), artistKey: { keys[$0] }, using: &generator)
            let sequence = order.map { keys[$0] }
            XCTAssertEqual(longestRun(sequence), 1, "seed \(seed)")
            let blanks = Set(sequence.indices.filter { sequence[$0].hasPrefix("song:") })
            let clustered = (0..<sequence.count).contains { start in
                (0..<4).allSatisfy { blanks.contains(start + $0) }
            }
            XCTAssertFalse(clustered, "blank names were still treated as one artist")
        }
    }

    func testArtistKeyFoldsCaseAndWhitespaceButKeepsAnId() {
        XCTAssertEqual(
            ArtistSeparatedShuffle.artistKey(id: nil, name: "  Jay Chou  ", fallback: "1"),
            ArtistSeparatedShuffle.artistKey(id: nil, name: "jay chou", fallback: "2")
        )
        XCTAssertNotEqual(
            ArtistSeparatedShuffle.artistKey(id: "UC1", name: "Jay", fallback: "1"),
            ArtistSeparatedShuffle.artistKey(id: "UC2", name: "Jay", fallback: "2")
        )
        XCTAssertNotEqual(
            ArtistSeparatedShuffle.artistKey(id: nil, name: " ", fallback: "a"),
            ArtistSeparatedShuffle.artistKey(id: nil, name: "", fallback: "b")
        )
    }

    func testLargeQueueStaysAPermutation() {
        let count = 2000
        let keys = (0..<count).map { "artist-\($0 % 25)" }
        var generator = Build51Generator(state: 51)
        let order = ArtistSeparatedShuffle.order(Array(keys.indices), artistKey: { keys[$0] }, using: &generator)
        XCTAssertEqual(order.count, count)
        XCTAssertEqual(Set(order).count, count)
        XCTAssertEqual(longestRun(order.map { keys[$0] }), 1)
    }

    private func longestRun(_ keys: [some Equatable]) -> Int {
        guard let first = keys.first else { return 0 }
        var best = 1
        var run = 1
        var previous = first
        for key in keys.dropFirst() {
            if key == previous {
                run += 1
                best = max(best, run)
            } else {
                run = 1
                previous = key
            }
        }
        return best
    }
}

private struct Build51Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}
