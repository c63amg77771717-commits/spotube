import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingManager {
    private var artworkTask: Task<Void, Never>?
    private var currentSongId: String?
    private var artwork: MPMediaItemArtwork?
    private weak var attachedPlayer: AVPlayer?
    private(set) var nowPlayingSession: MPNowPlayingSession?
    private var reportedTime: TimeInterval = 0
    private var reportedRate: Double = 0

    /// Pre-rendered fallback artwork created at init time so iOS never receives
    /// a 0×0 `UIImage()` from a closure that races SF-symbol rendering on cold
    /// start (F4). Reused across all songs that lack a thumbnail.
    private let fallbackArtwork: MPMediaItemArtwork

    init() {
        self.fallbackArtwork = Self.makeFallbackArtwork()
    }

    private static func makeFallbackArtwork() -> MPMediaItemArtwork {
        let size = CGSize(width: 300, height: 300)
        let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .regular)
        let symbol = UIImage(systemName: "music.note", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let symbol {
                let symbolSize = symbol.size
                let origin = CGPoint(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2
                )
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: rendered.size) { _ in rendered }
    }

    private var infoCenter: MPNowPlayingInfoCenter {
        nowPlayingSession?.nowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default()
    }

    /// Match iOS media ownership to the actual audio AVPlayer, not a mock
    /// playback flag or the separate muted video player.
    @discardableResult
    func attachPlayer(_ player: AVPlayer) -> MPNowPlayingSession {
        if attachedPlayer === player, let nowPlayingSession { return nowPlayingSession }
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
        attachedPlayer = player
        let session = MPNowPlayingSession(players: [player])
        // We own the title, artist, artwork, position and playback rate.
        session.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession = session
        // The old app-wide dictionary no longer represents our player.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        return session
    }

    func activateForCurrentPlayback() {
        guard currentSongId != nil, attachedPlayer?.currentItem != nil else { return }
        nowPlayingSession?.becomeActiveIfPossible { accepted in
            // On-device evidence: whether iOS accepted the audio player as
            // Control Center's active Now Playing session. No private data.
            PlaybackDiagnostics.shared.record(.init(
                phase: .nowPlayingSession, nowPlayingActive: accepted))
        }
    }

    func updateNowPlayingInfo(song: Song?, duration: TimeInterval) {
        guard let song else {
            artworkTask?.cancel()
            artworkTask = nil
            currentSongId = nil
            artwork = nil
            reportedTime = 0
            reportedRate = 0
            infoCenter.nowPlayingInfo = nil
            return
        }

        if currentSongId != song.id {
            artworkTask?.cancel()
            artworkTask = nil
            currentSongId = song.id
            artwork = nil
            reportedTime = 0
            reportedRate = 0
        }

        setNowPlayingInfo(song: song, duration: duration, artwork: artwork ?? fallbackArtwork)
        // Ready-to-play and metadata callbacks often repeat for the same song.
        // Do not restart a thumbnail fetch or reset playback status each time.
        guard artwork == nil, artworkTask == nil,
              let thumbnailURL = song.thumbnailURL, let url = URL(string: thumbnailURL) else {
            return
        }

        let songId = song.id
        artworkTask = Task {
            defer { artworkTask = nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, currentSongId == songId else { return }
                if let image = UIImage(data: data) {
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    setNowPlayingInfo(song: song, duration: duration, artwork: self.artwork)
                }
            } catch {
                // Artwork is optional — keep fallback
            }
        }
    }

    func updatePlaybackState(isPlaying: Bool, currentTime: TimeInterval, rate: Double) {
        // Guard against writing playback-state-only updates before the first
        // full `setNowPlayingInfo`. iOS rejects/garbles dictionaries that lack
        // title/artist (F7).
        reportedTime = currentTime.isFinite ? max(0, currentTime) : 0
        reportedRate = isPlaying && rate.isFinite ? max(0, rate) : 0
        guard var info = infoCenter.nowPlayingInfo,
              info[MPMediaItemPropertyTitle] != nil
        else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = reportedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = reportedRate
        infoCenter.nowPlayingInfo = info
    }

    private func setNowPlayingInfo(song: Song, duration: TimeInterval, artwork: MPMediaItemArtwork?) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artistName
        info[MPMediaItemPropertyAlbumTitle] = song.albumName
        // Omit duration when unknown so iOS doesn't classify the track as a
        // live stream of unknown length (F2). iOS will refresh once we write
        // again with a real duration.
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = reportedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = reportedRate
        // Deterministic media-type classification so CarPlay picks the right
        // template behavior (F6).
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPMediaItemPropertyArtwork] = artwork
        infoCenter.nowPlayingInfo = info
    }
}
