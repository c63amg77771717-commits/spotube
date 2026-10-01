import Foundation
import Security

final class YouTubeSearchKeyStore {
    private let service: String
    private let account = "youtube-data-api-key"

    init(service: String = "studio.evantube.youtube-search") {
        self.service = service
    }

    func read() throws -> String? {
        var query = lookup
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw StorageError.readFailed(status)
        }
        return value
    }

    func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StorageError.emptyKey }
        let attributes: [CFString: Any] = [
            kSecValueData: Data(key.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageError.writeFailed(status) }
        let insertion = lookup.merging(attributes) { _, value in value }
        let insertStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw StorageError.writeFailed(insertStatus) }
    }

    func remove() throws {
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.removeFailed(status)
        }
    }

    private var lookup: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private enum StorageError: LocalizedError {
        case emptyKey
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
        case removeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey:
                return "請輸入 YouTube 搜尋 API 金鑰。"
            case .readFailed(let status):
                return "無法讀取 YouTube 搜尋金鑰（Keychain \(status)），請解鎖裝置後再試。"
            case .writeFailed(let status):
                return "無法儲存 YouTube 搜尋金鑰（Keychain \(status)），請稍後再試。"
            case .removeFailed(let status):
                return "無法移除 YouTube 搜尋金鑰（Keychain \(status)），請稍後再試。"
            }
        }
    }
}
