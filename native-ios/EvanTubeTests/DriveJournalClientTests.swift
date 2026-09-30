import XCTest
@testable import LovelyMusic

private final class DriveHTTPStub: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DriveJournalClientTests: XCTestCase {
    private var session: URLSession!
    private var drive: DriveJournalClient!
    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DriveHTTPStub.self]
        session = URLSession(configuration: config)
        drive = DriveJournalClient(session: session)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        DriveHTTPStub.handle = nil
        super.tearDown()
    }

    func testPaginationAndScopeStayInsideAppData() async throws {
        var requests = 0
        DriveHTTPStub.handle = { request in
            requests += 1
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(parts.host, "www.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "spaces" })?.value, "appDataFolder")
            if requests == 1 {
                return (200, Data(#"{"files":[{"id":"fileA","name":"evantube-playlists-v1-a.json"}],"nextPageToken":"next"}"#.utf8))
            }
            XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "pageToken" })?.value, "next")
            return (200, Data(#"{"files":[{"id":"fileB","name":"evantube-playlists-v1-b.json"}]}"#.utf8))
        }
        let files = try await drive.list(token: "test-token")
        XCTAssertEqual(files.map(\.id), ["fileA", "fileB"])
        XCTAssertEqual(requests, 2)
    }

    func testRepeatedPaginationAndInvalidFileIDsAreRejected() async {
        DriveHTTPStub.handle = { _ in (200, Data(#"{"files":[],"nextPageToken":"same"}"#.utf8)) }
        do { _ = try await drive.list(token: "x"); XCTFail("Repeated page accepted") } catch {}
        DriveHTTPStub.handle = { _ in (200, Data(#"{"files":[{"id":"../escape","name":"evantube-playlists-v1-a.json"}]}"#.utf8)) }
        do { _ = try await drive.list(token: "x"); XCTFail("Invalid ID accepted") } catch {}
    }

    func testDeniedAndOversizedResponsesAreRejected() async {
        DriveHTTPStub.handle = { _ in (403, Data()) }
        do { _ = try await drive.list(token: "x"); XCTFail("Denied response accepted") } catch {}
        DriveHTTPStub.handle = { _ in (200, Data(repeating: 32, count: DriveJournalClient.maximumJournalBytes + 1)) }
        do {
            _ = try await drive.download([.init(id: "fileA", name: "evantube-playlists-v1-a.json")], token: "x")
            XCTFail("Oversized journal accepted")
        } catch {}
    }

    func testUploadOnlyUpdatesThisDeviceJournal() async throws {
        DriveHTTPStub.handle = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/upload/drive/v3/files/ownFile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Data(#"{"id":"ownFile"}"#.utf8))
        }
        try await drive.upload(Data(#"{"schemaVersion":1,"events":[]}"#.utf8), deviceID: "deviceA", existing: [
            .init(id: "otherFile", name: "evantube-playlists-v1-deviceB.json"),
            .init(id: "ownFile", name: "evantube-playlists-v1-deviceA.json")
        ], token: "x")
    }
}
