import AudioToolbox
import AVFoundation
import Foundation

/// Opus elementary stream pulled out of a WebM (YouTube itag 251).
struct WebMOpusStream: Equatable {
    var codecPrivate: Data
    var channels: Int
    var preSkip: Int
    var packets: [Data]

    var preSkipSeconds: TimeInterval { Double(preSkip) / 48_000 }
}

/// Parses the WebM subset YouTube serves for Opus and wraps it in CAF,
/// which AudioToolbox on iOS 17+ can decode. AVPlayer plays that CAF when it
/// can; otherwise the packets are decoded to AAC in an m4a. Either result is
/// a local file the existing player can seek, background, and hand to the
/// lock screen. Failure returns nil so AAC keeps playing.
enum WebMOpus {
    static func parse(_ data: Data) -> WebMOpusStream? {
        guard let segment = childPayload(id: 0x18538067, in: data, range: 0..<data.count) else { return nil }
        guard let tracks = childPayload(id: 0x1654AE6B, in: data, range: segment) else { return nil }
        var opusTrack: Int?
        var codecPrivate: Data?
        forEachChild(in: data, range: tracks) { id, payload in
            guard id == 0xAE else { return }
            var number: Int?
            var codec = ""
            var priv: Data?
            forEachChild(in: data, range: payload) { child, body in
                switch child {
                case 0xD7:
                    number = intValue(data, body)
                case 0x86:
                    codec = stringValue(data, body)
                case 0x63A2:
                    priv = Data(data[body])
                default:
                    break
                }
            }
            if codec == "A_OPUS", let priv {
                opusTrack = number ?? 1
                codecPrivate = priv
            }
        }
        guard let opusTrack, let codecPrivate, codecPrivate.count >= 12 else { return nil }
        var packets: [Data] = []
        forEachChild(in: data, range: segment) { id, payload in
            guard id == 0x1F43B675 else { return }
            forEachChild(in: data, range: payload) { child, body in
                if child == 0xA3 {
                    if let packet = simpleBlock(data, body, track: opusTrack) { packets.append(packet) }
                } else if child == 0xA0 {
                    forEachChild(in: data, range: body) { blockID, block in
                        guard blockID == 0xA1, let packet = simpleBlock(data, block, track: opusTrack) else { return }
                        packets.append(packet)
                    }
                }
            }
        }
        guard !packets.isEmpty else { return nil }
        let channels = Int(codecPrivate[codecPrivate.startIndex + 9])
        let preSkip = int16LE(codecPrivate, codecPrivate.startIndex + 10)
        return WebMOpusStream(codecPrivate: codecPrivate, channels: max(1, channels), preSkip: preSkip, packets: packets)
    }

    static func writeCAF(_ stream: WebMOpusStream, to url: URL) -> Bool {
        var body = Data()
        func chunk(_ type: String, _ payload: Data) {
            body.append(contentsOf: Array(type.utf8))
            body.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
            body.append(payload)
        }
        body.append(contentsOf: Array("caff".utf8))
        body.append(contentsOf: [0, 1, 0, 0])
        var desc = Data()
        func append32(_ value: UInt32, to data: inout Data) {
            data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        }
        desc.append(contentsOf: withUnsafeBytes(of: Double(48_000).bitPattern.bigEndian, Array.init))
        append32(0x6F707573, to: &desc) // 'opus'
        append32(0, to: &desc)
        append32(0, to: &desc)
        append32(960, to: &desc)
        append32(UInt32(stream.channels), to: &desc)
        append32(0, to: &desc)
        chunk("desc", desc)
        chunk("kuki", stream.codecPrivate)
        var pakt = Data()
        let priming = UInt32(max(0, stream.preSkip))
        let valid = max(0, stream.packets.count * 960 - Int(priming))
        func be64s(_ value: Int64, to data: inout Data) {
            data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        }
        be64s(Int64(stream.packets.count), to: &pakt)
        be64s(Int64(valid), to: &pakt)
        append32(priming, to: &pakt)
        append32(0, to: &pakt)
        for packet in stream.packets {
            var rest = packet.count
            while true {
                let bits = rest & 0x7F
                rest >>= 7
                if rest == 0 { pakt.append(UInt8(bits)); break }
                pakt.append(UInt8(bits | 0x80))
            }
        }
        chunk("pakt", pakt)
        var audio = Data([0, 0, 0, 0])
        for packet in stream.packets { audio.append(packet) }
        chunk("data", audio)
        do {
            try body.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// CAF when AVPlayer can read it, otherwise AAC in m4a decoded from that CAF.
    static func makePlayable(webm data: Data, directory: URL) async -> PreparedAudioUpgrade? {
        guard let stream = parse(data) else { return nil }
        let base = directory.appendingPathComponent("opus-\(UUID().uuidString)")
        let caf = base.appendingPathExtension("caf")
        guard writeCAF(stream, to: caf) else { return nil }
        if await isPlayable(caf) {
            return PreparedAudioUpgrade(fileURL: caf, timelineOffset: stream.preSkipSeconds, codec: "opus")
        }
        let m4a = base.appendingPathExtension("m4a")
        guard transcode(caf: caf, to: m4a), await isPlayable(m4a) else { return nil }
        // The decoder consumes Opus pre-skip while writing PCM, so the m4a
        // timeline already matches the video start.
        return PreparedAudioUpgrade(fileURL: m4a, timelineOffset: 0, codec: "opus")
    }

    static func downloadAndPrepare(remote: URL, headers: [String: String], contentLength: Int64?,
                                   session: URLSession) async -> PreparedAudioUpgrade? {
        if let contentLength, contentLength > 40 * 1024 * 1024 || contentLength <= 0 { return nil }
        var request = URLRequest(url: remote, timeoutInterval: 30)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let data = try Data(contentsOf: file)
            guard data.count > 32, data.count <= 40 * 1024 * 1024 else { return nil }
            return await makePlayable(webm: data, directory: FileManager.default.temporaryDirectory)
        } catch {
            return nil
        }
    }

    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    private static func transcode(caf: URL, to destination: URL) -> Bool {
        guard let input = try? AVAudioFile(forReading: caf) else { return false }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 192_000,
        ]
        guard let output = try? AVAudioFile(forWriting: destination, settings: settings) else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return false }
        do {
            while true {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: EBML

    private static func childPayload(id wanted: UInt64, in data: Data, range: Range<Int>) -> Range<Int>? {
        var found: Range<Int>?
        forEachChild(in: data, range: range) { id, payload in
            if id == wanted, found == nil { found = payload }
        }
        return found
    }

    private enum ElementSize { case known(Int), unknown }

    private static func forEachChild(in data: Data, range: Range<Int>, body: (UInt64, Range<Int>) -> Void) {
        var cursor = range.lowerBound
        while cursor + 2 <= range.upperBound {
            guard let id = readVInt(data, &cursor, stripMarker: false),
                  let size = readSize(data, &cursor) else { return }
            let end: Int
            switch size {
            case .known(let count):
                guard count >= 0, cursor <= range.upperBound - count else { return }
                end = cursor + count
            case .unknown:
                end = range.upperBound
            }
            body(id, cursor..<end)
            cursor = end
            if case .unknown = size { return }
        }
    }

    private static func simpleBlock(_ data: Data, _ range: Range<Int>, track: Int) -> Data? {
        var cursor = range.lowerBound
        guard let number = readVInt(data, &cursor, stripMarker: true), Int(number) == track,
              cursor + 3 <= range.upperBound else { return nil }
        cursor += 3 // timecode and flags
        guard cursor < range.upperBound else { return nil }
        return Data(data[cursor..<range.upperBound])
    }

    private static func readVInt(_ data: Data, _ cursor: inout Int, stripMarker: Bool) -> UInt64? {
        guard cursor < data.count else { return nil }
        let start = cursor
        let first = data[cursor]
        guard first != 0 else { return nil }
        var length = 1
        var marker: UInt8 = 0x80
        while length < 8 && first & marker == 0 {
            marker >>= 1
            length += 1
        }
        guard cursor + length <= data.count else { return nil }
        var raw = Data()
        for _ in 0..<length {
            raw.append(data[cursor])
            cursor += 1
        }
        if raw.allSatisfy({ $0 == 0xFF }) { cursor = start; return nil }
        var value: UInt64 = stripMarker ? UInt64(raw[0] & (marker == 0 ? 0xFF : marker - 1)) : UInt64(raw[0])
        // marker for length 8 is 0x01, marker - 1 = 0. Keep the low bits of the first byte.
        if stripMarker, length == 8 { value = UInt64(raw[0] & 0x01) }
        else if stripMarker { value = UInt64(raw[0] & (marker &- 1)) }
        for byte in raw.dropFirst() { value = (value << 8) | UInt64(byte) }
        return value
    }

    private static func readSize(_ data: Data, _ cursor: inout Int) -> ElementSize? {
        let start = cursor
        guard cursor < data.count else { return nil }
        let first = data[cursor]
        guard first != 0 else { return nil }
        var length = 1
        var marker: UInt8 = 0x80
        while length < 8 && first & marker == 0 {
            marker >>= 1
            length += 1
        }
        guard cursor + length <= data.count else { return nil }
        var raw = [UInt8]()
        for _ in 0..<length { raw.append(data[cursor]); cursor += 1 }
        if raw.allSatisfy({ $0 == 0xFF }) { return .unknown }
        var value: UInt64 = UInt64(raw[0] & (marker &- 1))
        if length == 8 { value = UInt64(raw[0] & 0x01) }
        for byte in raw.dropFirst() { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { cursor = start; return nil }
        return .known(Int(value))
    }

    private static func intValue(_ data: Data, _ range: Range<Int>) -> Int? {
        guard !range.isEmpty, range.count <= 8 else { return nil }
        var value: UInt64 = 0
        for byte in data[range] { value = (value << 8) | UInt64(byte) }
        return Int(value)
    }

    private static func stringValue(_ data: Data, _ range: Range<Int>) -> String {
        String(data: data[range], encoding: .utf8) ?? ""
    }

    private static func int16LE(_ data: Data, _ index: Data.Index) -> Int {
        guard data.distance(from: index, to: data.endIndex) >= 2 else { return 0 }
        let low = Int(data[index])
        let high = Int(data[data.index(after: index)])
        return low | (high << 8)
    }
}
