import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// Device-local artwork lives outside caches and is intentionally separate from Drive playlist data.
@MainActor @Observable
final class PlaylistCoverStore {
    static let shared = PlaylistCoverStore()
    private(set) var revision = 0
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlaylistCovers", isDirectory: true)) {
        self.directory = directory
        images.totalCostLimit = 24 * 1024 * 1024
    }

    func cover(for playlist: Playlist) -> (image: UIImage?, thumbnailURL: String?) {
        _ = revision
        let key = playlist.id as NSString
        if let image = images.object(forKey: key) {
            return (image, nil)
        }
        if let data = try? Data(contentsOf: fileURL(for: playlist.id)), let image = UIImage(data: data) {
            images.setObject(image, forKey: key, cost: imageCost(image))
            return (image, nil)
        }
        return (nil, playlist.automaticCoverURL)
    }

    func setCover(data: Data, for playlistId: String) throws {
        // ponytail: one bounded photo is normalized on the main actor; use a worker if imports stall.
        let jpeg = try Self.normalizedJPEG(data)
        guard let image = UIImage(data: jpeg) else { throw CoverError.invalidImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: fileURL(for: playlistId), options: .atomic)
        images.setObject(image, forKey: playlistId as NSString, cost: imageCost(image))
        revision &+= 1
    }

    func restoreAutomaticCover(for playlistId: String) throws {
        let file = fileURL(for: playlistId)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        images.removeObject(forKey: playlistId as NSString)
        revision &+= 1
    }

    private func fileURL(for playlistId: String) -> URL {
        let name = SHA256.hash(data: Data(playlistId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func normalizedJPEG(_ data: Data) throws -> Data {
        guard data.count <= 50 * 1024 * 1024 else { throw CoverError.imageTooLarge }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary) else { throw CoverError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CoverError.invalidImage }
        CGImageDestinationAddImage(destination, thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverError.invalidImage }
        return output as Data
    }

    enum CoverError: LocalizedError {
        case invalidImage, imageTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "無法讀取這張相片，請選擇其他圖片。"
            case .imageTooLarge: return "相片過大，請選擇小於 50 MB 的圖片。"
            }
        }
    }
}
