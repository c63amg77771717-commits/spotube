import Foundation

/// Spreads a queue so one artist's songs are not left in a block.
///
/// The previous shuffle was an in-memory Fisher-Yates of queue indices. That
/// is a uniform permutation: a playlist that arrives grouped by artist (an
/// album, an artist page, or a playlist stored in artist order) still has
/// long runs after the draw. The Up Next list also ignored that permutation
/// and kept walking the original array, so the grouped order stayed on screen.
///
/// This reorder only touches the songs already in memory. It does not sort the
/// catalog and it does not fetch anything, so starting playback stays as fast
/// as the old shuffle.
enum ArtistSeparatedShuffle {
    /// Songs that share an `artistId` stay one artist. A blank id falls back to
    /// the trimmed, case-insensitive name. A blank name does not become one
    /// giant "unknown" group — each such song keeps its own key.
    static func artistKey(id: String?, name: String, fallback: String) -> String {
        if let id {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return "id:\(trimmed)" }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty { return "name:\(trimmed)" }
        return "song:\(fallback)"
    }

    static func spread(_ songs: [Song], startingAt pinnedIndex: Int? = nil) -> [Song] {
        guard songs.count > 1 else { return songs }
        var generator = SystemRandomNumberGenerator()
        let indices = order(
            Array(songs.indices),
            artistKey: { index in
                artistKey(id: songs[index].artistId, name: songs[index].artistName, fallback: songs[index].id)
            },
            pinning: pinnedIndex,
            using: &generator
        )
        return indices.map { songs[$0] }
    }

    static func order(
        _ indices: [Int],
        artistKey: (Int) -> String,
        pinning pinned: Int? = nil,
        using rng: inout some RandomNumberGenerator
    ) -> [Int] {
        guard indices.count > 1 else { return indices }
        let pinnedIndex = pinned.flatMap { indices.contains($0) ? $0 : nil }
        let pool = pinnedIndex == nil ? indices : indices.filter { $0 != pinnedIndex }
        var placed = arrange(pool, artistKey: artistKey, using: &rng)
        guard let pinnedIndex else { return placed }
        if let next = placed.first, artistKey(next) == artistKey(pinnedIndex),
           let swap = placed.firstIndex(where: { artistKey($0) != artistKey(pinnedIndex) }) {
            placed.swapAt(0, swap)
        }
        placed.insert(pinnedIndex, at: 0)
        return placed
    }

    private static func arrange(
        _ pool: [Int],
        artistKey: (Int) -> String,
        using rng: inout some RandomNumberGenerator
    ) -> [Int] {
        guard pool.count > 1 else { return pool }
        var groups: [String: [Int]] = [:]
        for index in pool {
            groups[artistKey(index), default: []].append(index)
        }
        for key in Array(groups.keys) {
            var songs = groups[key] ?? []
            songs.shuffle(using: &rng)
            groups[key] = songs
        }
        var slots = [Int?](repeating: nil, count: pool.count)
        let orderedKeys = Array(groups.keys).shuffled(using: &rng).sorted { lhs, rhs in
            (groups[lhs]?.count ?? 0) > (groups[rhs]?.count ?? 0)
        }
        for key in orderedKeys {
            let songs = groups[key] ?? []
            guard !songs.isEmpty else { continue }
            let empty = slots.indices.filter { slots[$0] == nil }
            let local = positions(itemCount: songs.count, slotCount: empty.count)
            guard local.count == songs.count else { return pool }
            for (offset, song) in zip(local, songs) {
                guard empty.indices.contains(offset) else { return pool }
                slots[empty[offset]] = song
            }
        }
        let arranged = slots.compactMap { $0 }
        guard arranged.count == pool.count, Set(arranged).count == pool.count else { return pool }
        return arranged
    }

    /// Even slot picks. A majority artist is split by evenly placed holes so
    /// the longest run is as short as the counts allow. A minority artist is
    /// centered inside equal slices, which keeps equal groups from touching.
    private static func positions(itemCount: Int, slotCount: Int) -> [Int] {
        guard itemCount > 0, slotCount > 0 else { return [] }
        if itemCount >= slotCount { return Array(0..<slotCount) }
        if itemCount * 2 > slotCount {
            return majorityPositions(itemCount: itemCount, slotCount: slotCount)
        }
        return minorityPositions(itemCount: itemCount, slotCount: slotCount)
    }

    private static func majorityPositions(itemCount: Int, slotCount: Int) -> [Int] {
        let holes = slotCount - itemCount
        let chunks = holes + 1
        guard chunks > 0 else { return Array(0..<itemCount) }
        let base = itemCount / chunks
        let remainder = itemCount % chunks
        var positions: [Int] = []
        positions.reserveCapacity(itemCount)
        var index = 0
        for chunk in 0..<chunks {
            let size = base + (chunk < remainder ? 1 : 0)
            for _ in 0..<size {
                positions.append(index)
                index += 1
            }
            if index < slotCount { index += 1 }
        }
        return positions
    }

    private static func minorityPositions(itemCount: Int, slotCount: Int) -> [Int] {
        var used = Set<Int>()
        var positions: [Int] = []
        positions.reserveCapacity(itemCount)
        for item in 0..<itemCount {
            var ideal = Int((Double(item) + 0.5) * Double(slotCount) / Double(itemCount))
            if ideal < 0 { ideal = 0 }
            if ideal >= slotCount { ideal = slotCount - 1 }
            if used.contains(ideal) {
                for distance in 0..<slotCount {
                    let right = ideal + distance
                    let left = ideal - distance
                    if right < slotCount, !used.contains(right) {
                        ideal = right
                        break
                    }
                    if left >= 0, !used.contains(left) {
                        ideal = left
                        break
                    }
                }
            }
            used.insert(ideal)
            positions.append(ideal)
        }
        return positions
    }
}
