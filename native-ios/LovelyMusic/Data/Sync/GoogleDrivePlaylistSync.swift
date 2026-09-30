import Foundation
import GoogleSignIn
import Observation
import Security
import UIKit

enum DriveSyncError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum DriveWriterIdentity {
    // ThisDeviceOnly prevents an OS backup restored onto two phones from creating
    // two writers for one Drive file. Scope by event device ID so reinstalling
    // with a new local journal cannot overwrite the old installation's journal.
    static func id(for deviceID: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.c63amg77771717.evantube.drive-writer",
                                   kSecAttrAccount as String: deviceID,
                                   kSecAttrSynchronizable as String: false]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil { return id }
        guard status == errSecItemNotFound else {
            throw DriveSyncError.message("無法讀取此裝置的安全同步識別碼，請解鎖 iPhone 後重試。")
        }
        let id = UUID().uuidString.lowercased()
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(id.utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw DriveSyncError.message("無法儲存安全同步識別碼，本機歌單已保留。") }
        return id
    }
}

private final class DriveRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DriveJournalClient {
    static let prefix = "evantube-playlists-v1-"
    static let maximumJournalBytes = 5 * 1024 * 1024
    struct RemoteFile: Decodable {
        let id: String
        let name: String
    }
    struct Listing: Decodable {
        let files: [RemoteFile]
        let nextPageToken: String?
    }
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: config, delegate: DriveRedirectPolicy(), delegateQueue: nil)
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(string: "https://www.googleapis.com/\(path)")!
        parts.queryItems = query.isEmpty ? nil : query
        guard let result = parts.url else { throw DriveSyncError.message("無法建立雲端請求。") }
        return result
    }

    private func request(_ url: URL, token: String, method: String = "GET",
                         body: Data? = nil, contentType: String? = nil,
                         limit: Int = 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DriveSyncError.message("Google Drive 回應無效。")
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw DriveSyncError.message("Google 登入已失效，請重新登入。")
            case 403: throw DriveSyncError.message("Google Drive 拒絕存取。請確認已啟用 Drive API、完成測試使用者設定並授權同步。")
            case 429: throw DriveSyncError.message("Google Drive 請求過於頻繁，請稍後重試。")
            default: throw DriveSyncError.message("Google Drive 暫時無法同步（\(http.statusCode)），本機歌單已保留。")
            }
        }
        guard response.expectedContentLength <= Int64(limit) else {
            throw DriveSyncError.message("雲端歌單超過同步容量限制，本機資料已保留。")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else {
                throw DriveSyncError.message("雲端歌單超過同步容量限制，本機資料已保留。")
            }
            data.append(byte)
        }
        return data
    }

    static func validFileID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func cancelRequests() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func list(token: String) async throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        var page: String?
        var seenPages = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "spaces", value: "appDataFolder"),
                         URLQueryItem(name: "q", value: "trashed = false and name contains '\(Self.prefix)'"),
                         URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)"),
                         URLQueryItem(name: "pageSize", value: "100")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let data = try await request(url("drive/v3/files", query: query), token: token)
            let result = try JSONDecoder().decode(Listing.self, from: data)
            for file in result.files where file.name.hasPrefix(Self.prefix) && file.name.hasSuffix(".json") {
                guard Self.validFileID(file.id) else { throw DriveSyncError.message("雲端檔案識別碼無效。") }
                files.append(file)
            }
            guard files.count <= 128 else { throw DriveSyncError.message("雲端同步檔案過多，請先整理裝置備份。") }
            page = result.nextPageToken
            if let page, !seenPages.insert(page).inserted {
                throw DriveSyncError.message("Google Drive 分頁回應異常，請重試。")
            }
            guard seenPages.count <= 128 else { throw DriveSyncError.message("Google Drive 分頁超過限制。") }
        } while page != nil
        return files
    }

    func download(_ files: [RemoteFile], token: String) async throws -> [Data] {
        var journals: [Data] = []
        var size = 0
        for file in files {
            guard Self.validFileID(file.id) else { throw DriveSyncError.message("雲端檔案識別碼無效。") }
            let data = try await request(url("drive/v3/files/\(file.id)", query: [URLQueryItem(name: "alt", value: "media")]),
                                         token: token, limit: Self.maximumJournalBytes)
            size += data.count
            guard size <= 20 * 1024 * 1024 else { throw DriveSyncError.message("雲端歌單總量超過 20 MB，本機資料已保留。") }
            journals.append(data)
        }
        return journals
    }

    func upload(_ data: Data, deviceID: String, existing: [RemoteFile], token: String) async throws {
        guard data.count <= Self.maximumJournalBytes, Self.validFileID(deviceID) else {
            throw DriveSyncError.message("本機同步紀錄超過限制，尚未上傳。")
        }
        let name = "\(Self.prefix)\(deviceID).json"
        if let file = existing.filter({ $0.name == name }).sorted(by: { $0.id < $1.id }).first {
            guard Self.validFileID(file.id) else { throw DriveSyncError.message("雲端檔案識別碼無效。") }
            _ = try await request(url("upload/drive/v3/files/\(file.id)", query: [URLQueryItem(name: "uploadType", value: "media")]),
                                  token: token, method: "PATCH", body: data, contentType: "application/json")
        } else {
            let boundary = "evantube-\(UUID().uuidString)"
            let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"], "mimeType": "application/json"])
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body.append(metadata)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            _ = try await request(url("upload/drive/v3/files", query: [URLQueryItem(name: "uploadType", value: "multipart")]),
                                  token: token, method: "POST", body: body, contentType: "multipart/related; boundary=\(boundary)")
        }
    }
}

@MainActor @Observable
final class GoogleDrivePlaylistSync {
    static let shared = GoogleDrivePlaylistSync()
    static let scope = "https://www.googleapis.com/auth/drive.appdata"
    private let enabledKey = "evantube_drive_enabled_account"
    private let defaults = UserDefaults.standard
    private let client = DriveJournalClient()
    private var user: GIDGoogleUser?
    private var generation = 0
    private var restored = false
    private var pendingSync = false
    private var debounce: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private(set) var email: String?
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var lastSync: Date?
    private(set) var isEnabled = false

    private init() {
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    private func updateUser(_ value: GIDGoogleUser) {
        user = value
        email = value.profile?.email
        isEnabled = value.userID.map {
            defaults.string(forKey: enabledKey) == $0 && DrivePlaylistJournalStore.shared.isActivated(accountID: $0)
        } ?? false
        lastSync = value.userID.flatMap { defaults.object(forKey: "evantube_drive_last_sync_\($0)") as? Date }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        let restoringGeneration = generation
        if let value = try? await GIDSignIn.sharedInstance.restorePreviousSignIn(), generation == restoringGeneration {
            updateUser(value)
        }
    }

    func signIn() async {
        guard !isBusy else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var presenter = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        isBusy = true
        message = nil
        generation += 1
        defer { isBusy = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: [Self.scope])
            guard result.user.grantedScopes?.contains(Self.scope) == true else {
                throw DriveSyncError.message("尚未授權 Google Drive 歌單同步。")
            }
            updateUser(result.user)
        } catch {
            if (error as NSError).code != GIDSignInErrorCode.canceled.rawValue { message = error.localizedDescription }
        }
    }

    func activate() async {
        guard !isBusy, let id = user?.userID else { return }
        do {
            try LocalPlaylistRepository().activateDriveSync(accountID: id)
            defaults.set(id, forKey: enabledKey)
            isEnabled = true
            await sync()
        } catch { message = error.localizedDescription }
    }

    func disconnect() {
        generation += 1
        client.cancelRequests()
        debounce?.cancel()
        pendingSync = false
        defaults.removeObject(forKey: enabledKey)
        DrivePlaylistJournalStore.shared.deactivate()
        GIDSignIn.sharedInstance.signOut()
        user = nil
        email = nil
        isEnabled = false
        lastSync = nil
        message = nil
    }

    func scheduleSync() {
        guard isEnabled else { return }
        if isBusy { pendingSync = true; return }
        debounce?.cancel()
        debounce = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await sync()
        }
    }

    func startForeground() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task {
            await restore()
            while !Task.isCancelled {
                await sync()
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
            }
        }
    }

    func stopForeground() {
        foregroundTask?.cancel()
        foregroundTask = nil
        debounce?.cancel()
    }

    func sync() async {
        guard isEnabled, let current = user, let accountID = current.userID,
              DrivePlaylistJournalStore.shared.isActivated(accountID: accountID) else { return }
        guard !isBusy else { pendingSync = true; return }
        let sessionGeneration = generation
        isBusy = true
        message = nil
        defer {
            isBusy = false
            if pendingSync { pendingSync = false; scheduleSync() }
        }
        do {
            guard current.grantedScopes?.contains(Self.scope) == true else {
                throw DriveSyncError.message("請重新登入並授權 Google Drive 同步。")
            }
            let refreshed = try await current.refreshTokensIfNeeded()
            let token = refreshed.accessToken.tokenString
            let writerID = try DriveWriterIdentity.id(for: DrivePlaylistJournalStore.shared.deviceID)
            let files = try await client.list(token: token)
            let journals = try await client.download(files, token: token)
            try Task.checkCancellation()
            guard generation == sessionGeneration, isEnabled, user?.userID == accountID,
                  DrivePlaylistJournalStore.shared.isActivated(accountID: accountID) else { return }
            try LocalPlaylistRepository().mergeDriveJournals(journals)
            let payload = try DrivePlaylistJournalStore.shared.ownJournalData()
            try await client.upload(payload, deviceID: writerID, existing: files, token: token)
            guard generation == sessionGeneration, isEnabled, user?.userID == accountID else { return }
            let now = Date()
            defaults.set(now, forKey: "evantube_drive_last_sync_\(accountID)")
            lastSync = now
        } catch is CancellationError {
            // Pending local operations remain persisted for the next foreground sync.
        } catch {
            if generation == sessionGeneration { message = error.localizedDescription }
        }
    }
}
