import Foundation

/// Only typed metadata crosses this boundary; never pass headers, URLs or raw errors.
final class PlaybackDiagnostics: @unchecked Sendable {
    enum Phase: String, Codable, Sendable {
        case watchSession, visitor, playerResponse, streamResolved, engineReady, engineError, authChanged
    }
    enum Client: String, Codable, Sendable { case visionOS, iosSession, ios, webRemix }
    enum VisitorSource: String, Codable, Sendable { case tvPage, watchPage, appFallback }
    enum Reason: String, Codable, Sendable {
        case verificationRequired, signInRequired, regionRestricted, unavailable, network, other

        static func classify(_ message: String) -> Self {
            let text = message.lowercased()
            if ["not a bot", "不是機器人", "不是机器人"].contains(where: text.contains) { return .verificationRequired }
            if ["sign in", "login", "登入", "登录"].contains(where: text.contains) { return .signInRequired }
            if ["region", "country", "地區", "地区"].contains(where: text.contains) { return .regionRestricted }
            if ["unavailable", "private", "removed", "無法播放"].contains(where: text.contains) { return .unavailable }
            if ["network", "timed out", "timeout", "網路", "逾時"].contains(where: text.contains) { return .network }
            return .other
        }
    }
    struct Event: Codable, Sendable {
        let timestamp: Date
        let phase: Phase
        let client: Client?
        let videoID: String?
        let httpStatus: Int?
        let playabilityStatus: String?
        let reason: Reason?
        let hasAuth: Bool?
        let sessionAgeSeconds: Int?
        let visitorSource: VisitorSource?
        let hlsAvailable: Bool?
        let formatCount: Int?
        let transportErrorCode: Int?

        init(phase: Phase, client: Client? = nil, videoID: String? = nil,
             httpStatus: Int? = nil, playabilityStatus: String? = nil, reason: Reason? = nil,
             hasAuth: Bool? = nil, sessionAgeSeconds: Int? = nil, visitorSource: VisitorSource? = nil,
             hlsAvailable: Bool? = nil, formatCount: Int? = nil, transportErrorCode: Int? = nil,
             timestamp: Date = Date()) {
            self.timestamp = timestamp
            self.phase = phase
            self.client = client
            self.videoID = videoID.flatMap {
                $0.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil ? $0 : nil
            }
            let allowedStatuses = ["OK", "LOGIN_REQUIRED", "UNPLAYABLE", "ERROR", "LIVE_STREAM_OFFLINE", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED"]
            self.playabilityStatus = playabilityStatus.map { allowedStatuses.contains($0) ? $0 : "OTHER" }
            self.httpStatus = httpStatus
            self.reason = reason
            self.hasAuth = hasAuth
            self.sessionAgeSeconds = sessionAgeSeconds
            self.visitorSource = visitorSource
            self.hlsAvailable = hlsAvailable
            self.formatCount = formatCount
            self.transportErrorCode = transportErrorCode
        }
    }
    struct Report: Codable {
        let schemaVersion: Int
        let appVersion: String
        let appBuild: String
        let bundleID: String
        let systemVersion: String
        let storageError: Bool
        let events: [Event]
    }

    static let capacity = 100
    static let shared = PlaybackDiagnostics(fileURL:
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("EvanTube/PlaybackDiagnostics.json"))
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Event] = []
    private var storageError = false

    init(fileURL: URL) { self.fileURL = fileURL }
    var events: [Event] { lock.withLock { entries } }
    func record(_ event: Event) { }
    func clear() throws { }

    func reportData() throws -> Data {
        let snapshot = lock.withLock { (entries, storageError) }
        let report = Report(schemaVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            storageError: snapshot.1, events: snapshot.0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
