import Foundation
import Network

// Progressive playback for YouTube DASH audio (fMP4 + sidx).
//
// AVPlayer cannot stream the bare fMP4 from the network (err -12371/-12864),
// but it does play fMP4 inside HLS. The sidx index gives every fragment's byte
// range and duration, so a VOD playlist with EXT-X-MAP/EXT-X-BYTERANGE lets
// AVPlayer start after the first fragment and seek anywhere. AVPlayer reads
// the playlist and fragments from a loopback proxy because the CDN only allows
// a few ranges per signed URL; the proxy's fetcher rotates URLs as needed.

/// A complete fMP4 `sidx` box: where media starts and each fragment's byte
/// size and duration.
struct SIDXIndex: Equatable {
    struct Reference: Equatable {
        let size: Int
        let duration: UInt32
    }

    /// Offset of the sidx box; everything before it is ftyp + moov.
    let boxStart: Int
    let firstSegmentOffset: Int
    let timescale: UInt32
    let references: [Reference]

    var mediaEnd: Int { references.reduce(firstSegmentOffset) { $0 + $1.size } }

    /// Bytes from offset 0 needed to hold the whole sidx box, or nil while the
    /// box header itself is not present. Long songs have sidx boxes far larger
    /// than a 4 KB probe (a 3.5 h mix: 15 KB).
    static func requiredHeaderLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let start = sidxBoxStart(bytes), start + 8 <= bytes.count else { return nil }
        let size = Int(word(bytes, start))
        guard size >= 32 else { return nil }
        return start + size
    }

    /// Parses a fully present sidx box. A truncated box returns nil so later
    /// references are never silently dropped.
    static func parse(_ data: Data) -> SIDXIndex? {
        let bytes = [UInt8](data)
        guard let boxStart = sidxBoxStart(bytes) else { return nil }
        let boxSize = word(bytes, boxStart)
        guard boxSize >= 32, boxSize <= UInt64(bytes.count - boxStart) else { return nil }
        let boxEnd = boxStart + Int(boxSize)
        var cursor = boxStart + 8
        guard cursor + 4 <= boxEnd else { return nil }
        let version = bytes[cursor]
        guard version == 0 || version == 1 else { return nil }
        cursor += 4 // version and flags
        cursor += 4 // reference_id
        guard cursor + 4 <= boxEnd else { return nil }
        let timescale = UInt32(word(bytes, cursor))
        cursor += 4
        let firstOffset: UInt64
        if version == 0 {
            guard cursor + 8 <= boxEnd else { return nil }
            cursor += 4 // earliest presentation time
            firstOffset = word(bytes, cursor)
            cursor += 4
        } else {
            guard cursor + 16 <= boxEnd else { return nil }
            cursor += 8 // earliest presentation time
            firstOffset = (word(bytes, cursor) << 32) | word(bytes, cursor + 4)
            cursor += 8
        }
        guard firstOffset <= UInt64(Int.max - boxEnd), cursor + 4 <= boxEnd else { return nil }
        cursor += 2 // reserved
        let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
        cursor += 2
        guard count > 0, count <= (boxEnd - cursor) / 12 else { return nil }

        var references: [Reference] = []
        references.reserveCapacity(count)
        for _ in 0..<count {
            let entry = word(bytes, cursor)
            // Hierarchical references point at another index, not media.
            guard (entry & 0x8000_0000) == 0 else { return nil }
            let size = Int(entry & 0x7FFF_FFFF)
            guard size > 0 else { return nil }
            references.append(Reference(size: size, duration: UInt32(word(bytes, cursor + 4))))
            cursor += 12
        }
        return SIDXIndex(
            boxStart: boxStart,
            firstSegmentOffset: boxEnd + Int(firstOffset),
            timescale: timescale,
            references: references
        )
    }

    private static func sidxBoxStart(_ bytes: [UInt8]) -> Int? {
        let tag: [UInt8] = [0x73, 0x69, 0x64, 0x78]
        guard bytes.count >= 8 else { return nil }
        for i in 4...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == tag {
            return i - 4
        }
        return nil
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(bytes[offset]) << 24 | UInt64(bytes[offset + 1]) << 16
            | UInt64(bytes[offset + 2]) << 8 | UInt64(bytes[offset + 3])
    }
}

/// HLS VOD playlist over one fMP4 resource, addressed by byte range.
enum SegmentedHLSPlaylist {
    /// Returns nil when the index cannot describe the resource (no init
    /// section, zero timescale, or fragments running past the resource end).
    static func make(mediaURI: String, index: SIDXIndex, totalBytes: Int64) -> String? {
        guard index.boxStart > 0, index.timescale > 0, !index.references.isEmpty,
              Int64(index.mediaEnd) <= totalBytes,
              !mediaURI.contains("\""), !mediaURI.contains("\n"), !mediaURI.contains("\r")
        else { return nil }
        let timescale = Double(index.timescale)
        let longest = Double(index.references.map(\.duration).max() ?? 0) / timescale
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(mediaURI)\",BYTERANGE=\"\(index.boxStart)@0\"",
        ]
        var offset = index.firstSegmentOffset
        for reference in index.references {
            lines.append(String(format: "#EXTINF:%.6f,", Double(reference.duration) / timescale))
            lines.append("#EXT-X-BYTERANGE:\(reference.size)@\(offset)")
            lines.append(mediaURI)
            offset += reference.size
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The parts of an HTTP/1.1 request the loopback proxy needs.
struct LoopbackHTTPRequest: Equatable {
    let method: String
    let path: String
    let rangeHeader: String?

    /// nil until the full header block (terminated by CRLFCRLF) has arrived.
    init?(parsing data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1])
        rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
    }

    /// The requested byte range clamped to the resource, at most `cap` bytes.
    /// A missing Range header means the whole resource. Invalid or
    /// unsatisfiable ranges return nil (HTTP 416).
    func byteRange(totalBytes: Int64, cap: Int64) -> Range<Int64>? {
        guard totalBytes > 0 else { return nil }
        guard let rangeHeader else { return 0..<min(totalBytes, cap) }
        guard rangeHeader.lowercased().hasPrefix("bytes="), !rangeHeader.contains(",") else { return nil }
        let spec = rangeHeader.dropFirst("bytes=".count)
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let start: Int64
        var endExclusive: Int64
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            start = max(0, totalBytes - suffix)
            endExclusive = totalBytes
        } else {
            guard let first = Int64(bounds[0]), first < totalBytes else { return nil }
            start = first
            if bounds[1].isEmpty {
                endExclusive = totalBytes
            } else {
                guard let last = Int64(bounds[1]), last >= first else { return nil }
                endExclusive = min(last + 1, totalBytes)
            }
        }
        endExclusive = min(endExclusive, start + cap)
        return start..<endExclusive
    }
}

enum LoopbackHTTPResponse {
    static func make(status: Int, reason: String, headers: [(String, String)], body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers + [("Content-Length", "\(body.count)"), ("Connection", "close")] {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Serves one playlist and its media byte ranges on 127.0.0.1 for AVPlayer.
/// Paths carry a random token so other local processes cannot guess them.
final class LoopbackSegmentProxy: @unchecked Sendable {
    typealias Fetch = @Sendable (Range<Int64>) async throws -> Data

    // AVPlayer asks for one fragment per request; bound open-ended requests.
    static let maximumResponseBytes: Int64 = 4 * 1024 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "EvanTube.LoopbackSegmentProxy")
    private let token = UUID().uuidString
    private let totalBytes: Int64
    private let fetch: Fetch
    private var playlist = Data()

    init(totalBytes: Int64, fetch: @escaping Fetch) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        self.totalBytes = totalBytes
        self.fetch = fetch
    }

    var mediaPath: String { "/\(token)/media" }

    /// Starts listening and returns the playlist URL. `makePlaylist` receives
    /// the media URI to reference.
    func start(makePlaylist: (String) -> String?) async throws -> URL {
        let listener = self.listener
        let queue = self.queue
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let port = listener.port {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
        let base = "http://127.0.0.1:\(port.rawValue)"
        guard let text = makePlaylist(base + mediaPath),
              let url = URL(string: "\(base)/\(token)/index.m3u8")
        else {
            stop()
            throw AudioTransferIntegrityError.invalidIndex
        }
        queue.sync { playlist = Data(text.utf8) }
        return url
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = LoopbackHTTPRequest(parsing: buffer) {
                self.respond(to: request, on: connection)
            } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: LoopbackHTTPRequest, on connection: NWConnection) {
        let send: (Data) -> Void = { response in
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            send(LoopbackHTTPResponse.make(status: 405, reason: "Method Not Allowed", headers: [], body: Data()))
            return
        }
        let bodyless = request.method == "HEAD"
        if request.path == "/\(token)/index.m3u8" {
            let body = playlist
            send(LoopbackHTTPResponse.make(
                status: 200, reason: "OK",
                headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                body: bodyless ? Data() : body
            ))
            return
        }
        guard request.path == mediaPath else {
            send(LoopbackHTTPResponse.make(status: 404, reason: "Not Found", headers: [], body: Data()))
            return
        }
        guard let range = request.byteRange(totalBytes: totalBytes, cap: Self.maximumResponseBytes) else {
            send(LoopbackHTTPResponse.make(
                status: 416, reason: "Range Not Satisfiable",
                headers: [("Content-Range", "bytes */\(totalBytes)")], body: Data()
            ))
            return
        }
        let headers: [(String, String)] = [
            ("Content-Type", "audio/mp4"),
            ("Accept-Ranges", "bytes"),
            ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalBytes)"),
        ]
        if bodyless {
            send(LoopbackHTTPResponse.make(status: 206, reason: "Partial Content", headers: headers, body: Data()))
            return
        }
        let fetch = self.fetch
        Task {
            do {
                let body = try await fetch(range)
                send(LoopbackHTTPResponse.make(
                    status: 206, reason: "Partial Content", headers: headers, body: body
                ))
            } catch {
                send(LoopbackHTTPResponse.make(status: 502, reason: "Bad Gateway", headers: [], body: Data()))
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Fetches validated byte ranges of one CDN resource. The CDN allows only a
/// few ranges per signed URL (~5) before 403, so the URL is refreshed
/// proactively and on 403/410/429.
actor SegmentedCDNFetcher {
    typealias Refresh = @Sendable () async throws -> URL

    private var request: URLRequest
    private var rangesOnCurrentURL = 0
    private let totalBytes: Int64
    private let session: URLSession
    private let refresh: Refresh

    init(request: URLRequest, totalBytes: Int64, session: URLSession, refresh: @escaping Refresh) {
        self.request = request
        self.totalBytes = totalBytes
        self.session = session
        self.refresh = refresh
    }

    func fetch(_ range: Range<Int64>) async throws -> Data {
        if rangesOnCurrentURL >= 5 {
            try await refreshURL()
        }
        for attempt in 0..<2 {
            let ranged = try YouTubeCDNRangeRequest.applying(range, to: request)
            let (data, response) = try await session.data(for: ranged)
            if let http = response as? HTTPURLResponse,
               [403, 410, 429].contains(http.statusCode), attempt == 0 {
                try await refreshURL()
                continue
            }
            _ = try AudioTransferIntegrity.validate(
                response: response, receivedBytes: Int64(data.count),
                requestedRange: range, expectedTotal: totalBytes
            )
            rangesOnCurrentURL += 1
            return data
        }
        throw AudioTransferIntegrityError.incompleteResource
    }

    private func refreshURL() async throws {
        request.url = try await refresh()
        rangesOnCurrentURL = 0
    }
}
