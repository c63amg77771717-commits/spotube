import Foundation
import XCTest
@testable import LovelyMusic

/// End to end through the production progressive path: sidx index probe,
/// loopback HLS proxy, AVPlayer. The media is the deterministic 20 s AAC fMP4
/// fixture with a YouTube-style sidx; the CDN answers byte ranges with latency.
final class ProgressiveStartIntegrationTests: XCTestCase {
    @MainActor
    func testProgressiveStreamStartsWithoutSeekAndBeforeTheWholeFileArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try await DeterministicFMP4Fixture.generate(
            configuration: .twentySeconds, outputURL: directory.appendingPathComponent("fixture.mp4"),
            timeout: .seconds(30))
        let indexed = try YouTubeLikeFMP4.withSIDX(Data(contentsOf: generated.url),
                                                   totalSeconds: 20,
                                                   cadenceSeconds: generated.manifest.fragmentCadenceSeconds)
        XCTAssertGreaterThan(indexed.fragmentCount, 3, "the fixture must have several fragments")
        ProgressiveCDN.prepare(indexed.data)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveCDN.self]
        let session = URLSession(configuration: configuration)
        let engine = AudioEngine(audioTransferSession: session)
        defer { engine.stop(); session.invalidateAndCancel() }
        let url = "https://progressive-cdn.example.test/videoplayback?id=fixture"
        let total = Int64(indexed.data.count)
        engine.authCookieProvider = { nil }
        engine.streamURLResolver = { _ in (url: url, contentLength: total) }
        var song = Song(id: "PROGSTART01", title: "Progressive start fixture", artistName: "Fixture",
                        artistId: nil, albumName: nil, albumId: nil, duration: 20, thumbnailURL: nil)
        song.streamURL = url
        song.streamContentLength = total

        engine.play(song: song)
        var rangesAtFirstSecond: Int?
        for _ in 0..<750 {   // 15 s; the user never touches the progress bar
            if engine.lastError != nil || engine.currentTime >= 2 { break }
            if rangesAtFirstSecond == nil, engine.currentTime > 0 {
                rangesAtFirstSecond = ProgressiveCDN.mediaRequestCount()
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(engine.lastError)
        XCTAssertGreaterThanOrEqual(engine.currentTime, 2,
            "playback must start and advance on its own (it previously stalled at rate 0 until a seek)")
        XCTAssertLessThan(rangesAtFirstSecond ?? .max, indexed.fragmentCount + 2,
            "audio must start before every fragment was fetched")
    }
}

/// Inserts a YouTube-style sidx after moov: one reference per CMAF fragment.
enum YouTubeLikeFMP4 {
    struct Indexed {
        let data: Data
        let fragmentCount: Int
    }

    enum Failure: Error { case malformed }

    static func withSIDX(_ media: Data, totalSeconds: Double, cadenceSeconds: Double) throws -> Indexed {
        let bytes = [UInt8](media)
        var boxes: [(type: String, start: Int, size: Int)] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                           | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
            guard size >= 8, offset + size <= bytes.count else { throw Failure.malformed }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            boxes.append((type, offset, size))
            offset += size
        }
        guard let moov = boxes.firstIndex(where: { $0.type == "moov" }) else { throw Failure.malformed }
        let initEnd = boxes[moov].start + boxes[moov].size
        // A fragment begins at styp or moof and runs to the next one.
        var starts = boxes.indices.filter { $0 > moov && (boxes[$0].type == "moof" || boxes[$0].type == "styp") }
        starts = starts.filter { index in !(boxes[index].type == "moof" && index > 0 && boxes[index - 1].type == "styp") }
        guard !starts.isEmpty else { throw Failure.malformed }
        var fragments: [Range<Int>] = []
        for (n, index) in starts.enumerated() {
            let begin = boxes[index].start
            let end = n + 1 < starts.count ? boxes[starts[n + 1]].start : bytes.count
            fragments.append(begin..<end)
        }
        let timescale: UInt32 = 1000
        var durations = fragments.map { _ in UInt32(cadenceSeconds * 1000) }
        let assigned = durations.dropLast().reduce(0, +)
        durations[durations.count - 1] = UInt32(max(1, totalSeconds * 1000 - Double(assigned)))

        var sidx = Data()
        func word(_ value: UInt32) { sidx.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
        let size = UInt32(32 + 12 * fragments.count)
        word(size); sidx.append(contentsOf: Array("sidx".utf8))
        word(0); word(1); word(timescale); word(0); word(0)
        sidx.append(contentsOf: [0, 0]); sidx.append(contentsOf: withUnsafeBytes(of: UInt16(fragments.count).bigEndian, Array.init))
        for (fragment, duration) in zip(fragments, durations) {
            word(UInt32(fragment.count)); word(duration); word(0x9000_0000)
        }
        var output = Data(bytes[0..<initEnd])
        output.append(sidx)
        output.append(Data(bytes[fragments[0].lowerBound..<bytes.count]))
        return Indexed(data: output, fragmentCount: fragments.count)
    }
}

/// Byte-range CDN with per-request latency, like a real network.
final class ProgressiveCDN: URLProtocol {
    private static let lock = NSLock()
    private static var media = Data()   // guarded by lock
    private static var requests = 0

    static func prepare(_ data: Data) {
        lock.lock(); media = data; requests = 0; lock.unlock()
    }

    static func mediaRequestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "progressive-cdn.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let media = Self.media
        Self.requests += 1
        Self.lock.unlock()
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let start = min(bounds.first ?? 0, media.count - 1)
        let end = min(bounds.count > 1 ? bounds[1] : media.count - 1, media.count - 1)
        let body = media.subdata(in: start..<(end + 1))
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes \(start)-\(end)/\(media.count)", "Content-Length": "\(body.count)",
            "Content-Type": "audio/mp4"])!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
