import Foundation

/// Retains a complete subtitle field. Only explicit music artist endpoints establish
/// recording billing; an unclassified byline never silently becomes a performer.
enum MusicArtistCreditMapper {
    struct Credit {
        let name: String
        let id: String?
        let source: SongArtistNameSource
    }
    static func map(_ runs: [Run]?) -> Credit {
        let runs = runs ?? []
        var group: [Run] = []
        var index = 0
        while index < runs.count {
            group.append(runs[index])
            guard index + 1 < runs.count else { break }
            let separator = runs[index + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["•", "·", "‧", "・"].contains(separator) { break }
            index += 2
        }
        let complete = !group.isEmpty && group.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.navigationEndpoint?.browseEndpoint?.browseEndpointContextSupportedConfigs?
                    .browseEndpointContextMusicConfig?.pageType == "MUSIC_PAGE_TYPE_ARTIST"
        }
        return .init(name: group.map(\.text).joined(separator: ", "),
                     id: group.first?.navigationEndpoint?.browseEndpoint?.browseId,
                     source: complete ? .artistMetadata : .unknown)
    }
}
