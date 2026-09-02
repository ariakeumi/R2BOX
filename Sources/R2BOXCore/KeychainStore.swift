import Foundation
import Security

/// 读写 macOS Keychain 中的 Secret Access Key。
public struct KeychainStore: Sendable {
    public static let service = "dev.r2box.secrets"
    public init() {}

    public enum KeychainError: Error {
        case unhandled(OSStatus)
        case unexpectedData

        public var message: String {
            switch self {
            case .unhandled(let status): return "Keychain 操作失败 (OSStatus \(status))"
            case .unexpectedData: return "Keychain 返回了意外的数据格式"
            }
        }
    }

    public func setSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update = [kSecValueData as String: data] as CFDictionary
            let result = SecItemUpdate(query as CFDictionary, update)
            guard result == errSecSuccess else { throw KeychainError.unhandled(result) }
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let result = SecItemAdd(query as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.unhandled(result) }
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func getSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
