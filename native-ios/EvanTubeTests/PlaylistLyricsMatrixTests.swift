import Foundation
import XCTest
@testable import LovelyMusic

/// Fourteen entirely synthetic metadata cases; transport never leaves URLProtocol.
final class PlaylistLyricsMatrixTests: XCTestCase {
    func testTwelveSyntheticChineseCasesAndTwoEnglishControlsUseTheProductionRepository() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistLyricsMatrixFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let name = "PlaylistLyricsMatrix." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = LrcLibService(session: session, defaults: defaults)
        for row in PlaylistLyricsMatrixFixture.rows {
            let result = try await repository.getLyrics(title: row.raw, artist: "", duration: row.duration, allowVideoCredits: true)
            if row.title == nil { XCTAssertNil(result, row.raw) }
            else if row.manual {
                XCTAssertTrue(result?.lines.isEmpty ?? false, row.raw)
                XCTAssertEqual(result?.candidates.count, 1, "Missing performer requires user confirmation: \(row.raw)")
            } else {
                XCTAssertEqual(result?.lines.first?.text, "Selected fixture", row.raw)
                XCTAssertEqual(result?.isTimeSynced, true, row.raw)
            }
        }
    }
}

private final class PlaylistLyricsMatrixFixture: URLProtocol {
    struct Row {
        let raw: String
        let title: String?
        let artist: String?
        let duration: Int
        let manual: Bool
    }
    static let rows: [Row] = [
        .init(raw: "測試歌手 Alice - 晨光旋律 Morning Tune (Official Music Video)", title: "晨光旋律", artist: "測試歌手", duration: 180, manual: false),
        .init(raw: "測試歌手 - 夜色旋律『Synthetic quoted text』【動態歌詞】", title: "夜色旋律", artist: "測試歌手", duration: 181, manual: false),
        .init(raw: "測試歌手【星光旋律】Official MV", title: "星光旋律", artist: "測試歌手", duration: 182, manual: false),
        .init(raw: "晨風樂曲", title: "晨風樂曲", artist: "測試歌手", duration: 183, manual: true),
        .init(raw: "測試歌手 - 春日旋律 Official MV", title: "春日旋律", artist: "測試歌手", duration: 184, manual: false),
        .init(raw: "測試歌手 - 夏日旋律 Official MV", title: "夏日旋律", artist: "測試歌手", duration: 185, manual: false),
        .init(raw: "測試歌手 - 秋日旋律 Official MV", title: "秋日旋律", artist: "測試歌手", duration: 186, manual: false),
        .init(raw: "測試歌手 - 冬日旋律 Official MV", title: "冬日旋律", artist: "測試歌手", duration: 187, manual: false),
        .init(raw: "舞台樂曲 (Live)", title: "舞台樂曲 (Live)", artist: "測試歌手", duration: 188, manual: true),
        .init(raw: "測試歌手/範例歌手 - 合唱樂曲 (Live)", title: nil, artist: nil, duration: 189, manual: false),
        .init(raw: "測試歌手 - 雨聲旋律 Official MV", title: "雨聲旋律", artist: "測試歌手", duration: 190, manual: false),
        .init(raw: "測試歌手 - 雪夜旋律 Official MV", title: "雪夜旋律", artist: "測試歌手", duration: 191, manual: false),
        .init(raw: "Fixture Artist - Fixture Song 1 (official video)", title: "Fixture Song 1", artist: "Fixture Artist", duration: 220, manual: false),
        .init(raw: "Fixture Artist - Fixture Song 2 (official video)", title: "Fixture Song 2", artist: "Fixture Artist", duration: 221, manual: false)
    ]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let title = query.first { $0.name == "track_name" }!.value!
        let artist = query.first { $0.name == "artist_name" }?.value
        let isSearch = request.url!.lastPathComponent == "search"
        let row = Self.rows.first { $0.title == title && ($0.artist == artist || (isSearch && $0.manual && artist == nil)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: isSearch ? 200 : (row == nil ? 404 : 200), httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var payload: [String: Any]?
        if let row {
            payload = ["trackName": row.title!, "artistName": row.artist!, "duration": Double(row.duration), "syncedLyrics": "[00:01.00]Selected fixture"]
            if row.manual { payload!["id"] = 123 }
        }
        if isSearch {
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload.map { [$0] } ?? []))
        } else if let payload {
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
