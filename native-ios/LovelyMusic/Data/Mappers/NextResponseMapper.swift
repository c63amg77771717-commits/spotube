import Foundation

enum NextResponseMapper {
    private static let decoder = JSONDecoder()

    static func map(_ data: Data) throws -> [Song] {
        let response = try decoder.decode(NextResponse.self, from: data)
        return mapSongs(response)
    }

    private static func mapSongs(_ response: NextResponse) -> [Song] {
        let tabs = response.contents?.singleColumnMusicWatchNextResultsRenderer?
            .tabbedRenderer?.watchNextTabbedResultsRenderer?.tabs ?? []

        guard let upNextTab = tabs.first else { return [] }

        let contents = upNextTab.tabRenderer?.content?.musicQueueRenderer?
            .content?.playlistPanelRenderer?.contents ?? []

        return contents.compactMap { content -> Song? in
            guard let renderer = content.playlistPanelVideoRenderer else { return nil }

            let title = renderer.title?.text ?? ""
            guard let videoId = renderer.videoId, !title.isEmpty else { return nil }

            let longRuns = renderer.longBylineText?.runs
            let credit = MusicArtistCreditMapper.map(longRuns?.isEmpty == false ? longRuns : renderer.shortBylineText?.runs)
            let artistName = credit.name
            let artistId = credit.id

            let thumbnailURL = renderer.thumbnail?.thumbnails?.last?.url

            let durationText = renderer.lengthText?.text
            let duration = SearchResponseMapper.parseDuration(durationText)

            let musicVideoType = renderer.navigationEndpoint?.watchEndpoint?
                .watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType

            return Song(
                id: videoId,
                title: title,
                artistName: artistName,
                artistId: artistId,
                albumName: nil,
                albumId: nil,
                duration: duration,
                thumbnailURL: thumbnailURL,
                artistNameSource: credit.source,
                musicVideoType: musicVideoType
            )
        }
    }
}
