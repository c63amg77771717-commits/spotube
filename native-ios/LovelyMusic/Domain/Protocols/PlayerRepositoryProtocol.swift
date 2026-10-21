import Foundation

protocol PlayerRepositoryProtocol {
    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)?
    /// Report a resolved candidate that failed media-format/integrity validation.
    /// Transport, authentication and explicit playability failures are not candidates.
    func reportPlaybackCandidateFailure(videoId: String, streamURL: String)
    /// Clear temporary candidate exclusions after this exact stream really plays.
    func reportPlaybackCandidateSuccess(videoId: String, streamURL: String)
}

extension PlayerRepositoryProtocol {
    func reportPlaybackCandidateFailure(videoId: String, streamURL: String) {}
    func reportPlaybackCandidateSuccess(videoId: String, streamURL: String) {}

    func resolveStreamDescriptor(
        videoId: String,
        quality: AudioQuality,
        requestHeaders: [String: String]
    ) async throws -> StreamDescriptor {
        throw StreamDescriptorError.descriptorResolutionUnsupported
    }
}
