import Foundation
import ZIPFoundation

struct MB3ImportedPlaylist: Identifiable {
    let id: String                 // MB3 source identity; never used as a playback ID.
    let name: String
    let songs: [Song]              // Only validated YouTube IDs are playable here.
    let skipped: Int
}

struct MB3ImportDocument {
    let playlists: [MB3ImportedPlaylist]
    let rowCount: Int
    let skipped: Int
}

enum MB3ImportError: LocalizedError {
    case tooLarge
    case unsafeArchive
    case unsupportedFormat
    case noPlayableSongs

    var errorDescription: String? {
        switch self {
        case .tooLarge: "歌單檔案過大，請分批匯入。"
        case .unsafeArchive: "ZIP 包含不安全或無法讀取的內容。"
        case .unsupportedFormat: "找不到 MB3 歌單 JSON，請重新匯出。"
        case .noPlayableSongs: "沒有可匯入的 YouTube 歌曲。"
        }
    }
}

enum MB3PlaylistImporter {
    static let maximumCompressedBytes = 32 * 1024 * 1024
    static let maximumUncompressedBytes: UInt64 = 64 * 1024 * 1024
    static let maximumEntries = 512
    static let maximumRows = 20_000

    static func parse(zipURL: URL) throws -> MB3ImportDocument {
        let values = try zipURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize <= maximumCompressedBytes else {
            throw MB3ImportError.tooLarge
        }
        let archive = try Archive(url: zipURL, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= maximumEntries else { throw MB3ImportError.tooLarge }

        var total: UInt64 = 0
        for entry in entries {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !path.contains(":"), !parts.contains(".."),
                  entry.type != .symlink else {
                throw MB3ImportError.unsafeArchive
            }
            guard entry.uncompressedSize <= maximumUncompressedBytes - total else {
                throw MB3ImportError.tooLarge
            }
            total += entry.uncompressedSize
        }

        let jsonEntries = entries.filter {
            $0.type == .file && $0.path.lowercased().hasSuffix(".json")
                && !$0.path.hasPrefix("__MACOSX/")
        }
        guard !jsonEntries.isEmpty else { throw MB3ImportError.unsupportedFormat }
        let selected = jsonEntries.first {
            $0.path.split(separator: "/").last?.lowercased() == "mb3_all_playlists.json"
        }.map { [$0] } ?? jsonEntries

        var documents: [MB3ImportDocument] = []
        for entry in selected {
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            let checksum = try archive.extract(entry, consumer: { chunk in
                guard data.count + chunk.count <= Int(maximumUncompressedBytes) else {
                    throw MB3ImportError.tooLarge
                }
                data.append(chunk)
            })
            guard checksum == entry.checksum else { throw MB3ImportError.unsafeArchive }
            documents.append(try parseJSON(data))
        }
        let playlists = documents.flatMap(\.playlists)
        guard playlists.contains(where: { !$0.songs.isEmpty }) else {
            throw MB3ImportError.noPlayableSongs
        }
        return MB3ImportDocument(
            playlists: playlists,
            rowCount: documents.reduce(0) { $0 + $1.rowCount },
            skipped: documents.reduce(0) { $0 + $1.skipped }
        )
    }

    static func parseJSON(_ data: Data) throws -> MB3ImportDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MB3ImportError.unsupportedFormat
        }
        let metadata = root["playlists"] as? [[String: Any]] ?? []
        let rows = root["songs"] as? [[String: Any]] ?? []
        guard rows.count <= maximumRows else { throw MB3ImportError.tooLarge }
        guard !metadata.isEmpty || !rows.isEmpty else { throw MB3ImportError.unsupportedFormat }

        struct Group {
            var name: String
            var songs: [(order: Int, song: Song)] = []
            var seen: Set<String> = []
            var skipped = 0
        }
        var groups: [String: Group] = [:]
        var orderedKeys: [String] = []

        func key(_ row: [String: Any]) -> String {
            let category = value(row["category"])
            let id = value(row["playlist_id"])
            let name = value(row["playlist_name"] ?? row["name"])
            return id.isEmpty ? "name:\(name)" : "\(category):\(id)"
        }
        func ensure(_ row: [String: Any]) -> String {
            let id = key(row)
            let name = value(row["playlist_name"] ?? row["name"])
            if groups[id] == nil {
                orderedKeys.append(id)
                groups[id] = Group(name: name.isEmpty ? "未命名歌單" : name)
            }
            return id
        }

        for row in metadata { _ = ensure(row) }
        for (index, row) in rows.enumerated() {
            let id = ensure(row)
            let videoID = value(row["youtube_id"] ?? row["videoId"] ?? row["video_id"])
            guard isYouTubeID(videoID) else {
                groups[id]?.skipped += 1
                continue
            }
            guard groups[id]?.seen.insert(videoID).inserted == true else {
                groups[id]?.skipped += 1
                continue
            }
            let rawTitle = value(row["title"] ?? row["name"])
            let title = rawTitle.isEmpty ? videoID : rawTitle
            let artist = value(row["artist"] ?? row["artist_name"])
            let duration = Int(value(row["duration_seconds"]))
            let song = Song(
                id: videoID, title: title, artistName: artist,
                artistId: nil, albumName: nil, albumId: nil,
                duration: duration,
                thumbnailURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
            )
            let order = Int(value(row["order"])) ?? (index + 1)
            groups[id]?.songs.append((order: order, song: song))
        }
        let playlists = orderedKeys.compactMap { id -> MB3ImportedPlaylist? in
            guard let group = groups[id] else { return nil }
            return MB3ImportedPlaylist(
                id: id, name: group.name,
                songs: group.songs.sorted { $0.order < $1.order }.map(\.song),
                skipped: group.skipped
            )
        }
        return MB3ImportDocument(
            playlists: playlists, rowCount: rows.count,
            skipped: playlists.reduce(0) { $0 + $1.skipped }
        )
    }

    private static func value(_ raw: Any?) -> String {
        if let text = raw as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    private static func isYouTubeID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return bytes.count == 11 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
