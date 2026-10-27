import Foundation

/// What plays first, what we try to upgrade to, and what remains when that fails.
///
/// Startup is the AAC `bestAudioFormat` already used by Build45, so Opus work
/// cannot move time-to-first-audio. Opus is itag 251 (WebM, ~160 kbps) when the
/// player response includes it. The AAC fallback prefers itag 141 when the
/// quality cap allows it, otherwise itag 140.
enum AudioSourcePlan {
    struct Selection: Equatable {
        let startup: StreamFormat
        let opusUpgrade: StreamFormat?
        let aacFallback: StreamFormat
    }

    static func select(from data: StreamingData, quality: AudioQuality = .high) -> Selection? {
        guard let startup = data.bestAudioFormat(quality: quality) else { return nil }
        let cap = quality.maxBitrate()
        let headroom = cap + cap / 10
        let aac = data.allFormats.filter {
            $0.url != nil && StreamMIMEBaseSyntax.normalizedBase($0.mimeType) == "audio/mp4"
        }
        let preferred = aac.first { $0.itag == 141 } ?? aac.first { $0.itag == 140 }
        let fallback: StreamFormat
        if let preferred, preferred.itag == startup.itag || (preferred.bitrate ?? 0) <= headroom {
            fallback = preferred
        } else {
            fallback = startup
        }
        return Selection(startup: startup, opusUpgrade: data.preferredOpusFormat(), aacFallback: fallback)
    }
}

extension StreamingData {
    /// YouTube itag 251, or another audio/webm Opus stream with a URL.
    func preferredOpusFormat() -> StreamFormat? {
        let webm = allFormats.filter {
            $0.url?.isEmpty == false && StreamMIMEBaseSyntax.normalizedBase($0.mimeType) == "audio/webm"
        }
        return webm.first { $0.itag == 251 }
            ?? webm.first { $0.mimeType.lowercased().contains("opus") }
    }
}

/// A local file AVPlayer can switch to without waiting on the network again.
struct PreparedAudioUpgrade: Sendable {
    let fileURL: URL
    let timelineOffset: TimeInterval
    let codec: String
}
