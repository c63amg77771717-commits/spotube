import XCTest
@testable import LovelyMusic

final class SegmentedAudioStreamTests: XCTestCase {
    /// 8-byte stand-in for ftyp+moov, then a 56-byte sidx (timescale 1000,
    /// first_offset 4) with fragments of 5 bytes/2.5 s and 7 bytes/10 s.
    private var indexedHeader: Data {
        Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]) + Data([
            0, 0, 0, 56, 0x73, 0x69, 0x64, 0x78,
            0, 0, 0, 0, // version/flags
            0, 0, 0, 1, // reference_id
            0, 0, 3, 232, // timescale 1000
            0, 0, 0, 0, // earliest presentation time
            0, 0, 0, 4, // first_offset
            0, 0, 0, 2, // reserved + reference_count
            0, 0, 0, 5, 0, 0, 9, 196, 0, 0, 0, 0, // 5 bytes, 2500 ticks
            0, 0, 0, 7, 0, 0, 39, 16, 0, 0, 0, 0, // 7 bytes, 10000 ticks
        ])
    }

    func testIndexKeepsDurationsAndInitSection() throws {
        let index = try XCTUnwrap(SIDXIndex.parse(indexedHeader))
        XCTAssertEqual(index.boxStart, 8)
        XCTAssertEqual(index.firstSegmentOffset, 68)
        XCTAssertEqual(index.timescale, 1000)
        XCTAssertEqual(index.references, [.init(size: 5, duration: 2500), .init(size: 7, duration: 10000)])
        XCTAssertEqual(index.mediaEnd, 80)
        // The download path's view of the same index is unchanged.
        let legacy = parseSIDX(indexedHeader)
        XCTAssertEqual(legacy.headerEnd, 68)
        XCTAssertEqual(legacy.segmentSizes, [5, 7])
    }

    func testTruncatedIndexReportsTheBytesItNeeds() {
        let truncated = Data(indexedHeader.prefix(40))
        XCTAssertNil(SIDXIndex.parse(truncated))
        XCTAssertEqual(SIDXIndex.requiredHeaderLength(truncated), 64)
        XCTAssertNil(SIDXIndex.requiredHeaderLength(Data(indexedHeader.prefix(6))))
    }

    func testPlaylistAddressesInitAndEveryFragmentByByteRange() throws {
        let index = try XCTUnwrap(SIDXIndex.parse(indexedHeader))
        let playlist = try XCTUnwrap(
            SegmentedHLSPlaylist.make(mediaURI: "http://127.0.0.1:9/t/media", index: index, totalBytes: 80)
        )
        XCTAssertEqual(playlist, """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:10
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="http://127.0.0.1:9/t/media",BYTERANGE="8@0"
        #EXTINF:2.500000,
        #EXT-X-BYTERANGE:5@68
        http://127.0.0.1:9/t/media
        #EXTINF:10.000000,
        #EXT-X-BYTERANGE:7@73
        http://127.0.0.1:9/t/media
        #EXT-X-ENDLIST

        """)
    }

    func testPlaylistRejectsAnIndexLongerThanTheResource() throws {
        let index = try XCTUnwrap(SIDXIndex.parse(indexedHeader))
        XCTAssertNil(SegmentedHLSPlaylist.make(mediaURI: "http://127.0.0.1:9/t/media", index: index, totalBytes: 79))
    }

    func testRangeHeaderParsing() throws {
        func range(_ header: String?) -> Range<Int64>? {
            var raw = "GET /t/media HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            if let header { raw += "Range: \(header)\r\n" }
            raw += "\r\n"
            return LoopbackHTTPRequest(parsing: Data(raw.utf8))?.byteRange(totalBytes: 100, cap: 30)
        }
        XCTAssertEqual(range("bytes=10-19"), 10..<20)
        XCTAssertEqual(range("bytes=90-"), 90..<100)
        XCTAssertEqual(range("bytes=-5"), 95..<100)
        XCTAssertEqual(range("bytes=0-99"), 0..<30, "capped")
        XCTAssertEqual(range(nil), 0..<30)
        XCTAssertEqual(range("bytes=95-200"), 95..<100)
        XCTAssertNil(range("bytes=100-"))
        XCTAssertNil(range("bytes=20-10"))
        XCTAssertNil(range("bytes=0-1,5-6"))
        XCTAssertNil(range("items=0-1"))
        XCTAssertNil(LoopbackHTTPRequest(parsing: Data("GET /t/media HTTP/1.1\r\n".utf8)), "headers incomplete")
    }

    func testProxyServesPlaylistAndExactByteRanges() async throws {
        let resource = Data((0..<80).map { UInt8($0) })
        let proxy = try LoopbackSegmentProxy(totalBytes: 80) { range in
            resource.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        defer { proxy.stop() }
        let index = try XCTUnwrap(SIDXIndex.parse(indexedHeader))
        let playlistURL = try await proxy.start { mediaURI in
            SegmentedHLSPlaylist.make(mediaURI: mediaURI, index: index, totalBytes: 80)
        }
        XCTAssertEqual(playlistURL.host, "127.0.0.1")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (playlistData, playlistResponse) = try await session.data(from: playlistURL)
        XCTAssertEqual((playlistResponse as? HTTPURLResponse)?.statusCode, 200)
        let playlist = try XCTUnwrap(String(data: playlistData, encoding: .utf8))
        XCTAssertTrue(playlist.hasPrefix("#EXTM3U\n"))
        let mediaURL = try XCTUnwrap(URL(string: try XCTUnwrap(playlist.split(separator: "\n").last { !$0.hasPrefix("#") }).description))

        var request = URLRequest(url: mediaURL)
        request.setValue("bytes=68-72", forHTTPHeaderField: "Range")
        let (body, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 68-72/80")
        XCTAssertEqual(body, resource.subdata(in: 68..<73))

        var wrongToken = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false)!
        wrongToken.path = "/guess/media"
        let (_, missing) = try await session.data(from: wrongToken.url!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }

    func testFetcherRejectsRefusedURLAndOnlyRefreshesProactivelyAfterFiveRanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SegmentedCDNStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let refused = URL(string: "https://cdn.segmented.test/refused")!
        let working = URL(string: "https://cdn.segmented.test/working")!
        let rejections = RejectionLog()
        let fetcher = SegmentedCDNFetcher(
            request: URLRequest(url: refused), totalBytes: 80, session: session,
            refresh: { rejecting in
                await rejections.append(rejecting)
                return working
            }
        )

        let first = try await fetcher.fetch(0..<8)
        XCTAssertEqual(first, SegmentedCDNStub.resource.subdata(in: 0..<8))
        let afterRefusal = await rejections.entries
        XCTAssertEqual(afterRefusal, [refused], "403 rejects the refused URL's source")

        for start in stride(from: 8, to: 40, by: 8) {
            _ = try await fetcher.fetch(Int64(start)..<Int64(start + 8))
        }
        let beforeProactive = await rejections.entries
        XCTAssertEqual(beforeProactive.count, 1, "five ranges on the working URL need no refresh")
        _ = try await fetcher.fetch(40..<48)
        let afterProactive = await rejections.entries
        XCTAssertEqual(afterProactive, [refused, nil], "proactive refresh rejects nothing")
    }

    func testProxyReportsFetchFailureAsBadGateway() async throws {
        let proxy = try LoopbackSegmentProxy(totalBytes: 80) { _ in
            throw AudioTransferIntegrityError.incompleteResource
        }
        defer { proxy.stop() }
        let index = try XCTUnwrap(SIDXIndex.parse(indexedHeader))
        let playlistURL = try await proxy.start { mediaURI in
            SegmentedHLSPlaylist.make(mediaURI: mediaURI, index: index, totalBytes: 80)
        }
        let mediaURL = playlistURL.deletingLastPathComponent().appendingPathComponent("media")
        var request = URLRequest(url: mediaURL)
        request.setValue("bytes=0-7", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
    }
}

private actor RejectionLog {
    private(set) var entries: [URL?] = []
    func append(_ url: URL?) { entries.append(url) }
}

/// CDN double: path "/refused" answers 403; anything else serves byte ranges
/// of an 80-byte resource with a correct Content-Range.
final class SegmentedCDNStub: URLProtocol {
    static let resource = Data((0..<80).map { UInt8($0) })

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cdn.segmented.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/refused" {
            let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let start = bounds.first ?? 0
        let end = bounds.count > 1 ? bounds[1] : Self.resource.count - 1
        let body = Self.resource.subdata(in: start..<(end + 1))
        let response = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(start)-\(end)/\(Self.resource.count)",
                           "Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
