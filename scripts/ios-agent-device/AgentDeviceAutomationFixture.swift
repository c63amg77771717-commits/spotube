#if DEBUG
import Foundation

/// Installed only by the isolated simulator CI recipe, never shipped in the IPA.
enum AgentDeviceFixtureLog {
    private static let lock = NSLock()
    static func record(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var event = values
        event["time"] = Date().timeIntervalSince1970
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = root.appendingPathComponent("agent-device-fixture.ndjson")
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

actor AgentDevicePlayerFixture: PlayerRepositoryProtocol {
    private var attempts: [String: Int] = [:]
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        attempts[videoId, default: 0] += 1
        let attempt = attempts[videoId]!
        let transient = ProcessInfo.processInfo.environment["EVANTUBE_AGENT_SCENARIO"] == "transient"
            && attempt % 2 == 1
        AgentDeviceFixtureLog.record(["kind": "audio", "videoID": videoId,
            "attempt": attempt, "outcome": transient ? "transient" : "local_wav"])
        if transient { throw URLError(.timedOut) }
        guard let url = Bundle.main.url(forResource: "agent_device_audio", withExtension: "wav") else {
            throw URLError(.fileDoesNotExist)
        }
        return (url.absoluteString, nil)
    }
    func resolveStreamDescriptor(videoId: String, quality: AudioQuality,
        requestHeaders: [String: String]) async throws -> StreamDescriptor {
        throw StreamDescriptorError.localResourceIsNotRemoteRangeEligible
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? { nil }
}

final class AgentDeviceLyricsProtocol: URLProtocol {
    private let stateLock = NSLock()
    private var finished = false
    private var stopped = false
    private var work: DispatchWorkItem?
    static func session() -> URLSession {
        if ProcessInfo.processInfo.environment["EVANTUBE_LYRICS_CANDIDATE_RESET"] == "1" {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("lyrics.selection.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [AgentDeviceLyricsProtocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let title = query.first { $0.name == "track_name" || $0.name == "title" }?.value ?? "Arcadia"
        let artist = query.first { $0.name == "artist_name" || $0.name == "artist" }?.value ?? "Fixture Artist"
        let delayed = title == "Agent Next" && ProcessInfo.processInfo.environment["EVANTUBE_AGENT_SCENARIO"] == "stale"
        AgentDeviceFixtureLog.record(["kind": "lyrics_start", "title": title, "delayed": delayed])
        let action = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard !self.stopped else { self.stateLock.unlock(); return }
            self.finished = true
            self.stateLock.unlock()
            let row: [String: Any] = ["id": 701, "trackName": title, "artistName": artist,
                "duration": 98.0, "syncedLyrics": "[00:01.00]Agent lyrics \(title)"]
            let payload: Any = url.lastPathComponent == "search" ? [row] : row
            AgentDeviceFixtureLog.record(["kind": "lyrics_deliver", "title": title])
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = action
        DispatchQueue.global().asyncAfter(deadline: .now() + (delayed ? 8 : 0.05), execute: action)
    }
    override func stopLoading() {
        stateLock.lock(); stopped = true; let cancelled = !finished; stateLock.unlock()
        work?.cancel()
        if cancelled {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let title = query.first { $0.name == "track_name" || $0.name == "title" }?.value ?? ""
            AgentDeviceFixtureLog.record(["kind": "lyrics_cancel", "title": title])
        }
    }
}
#endif
