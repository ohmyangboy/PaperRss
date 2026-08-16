import Foundation
import Security

/// 凭据安全持久化抽象协议。
///
/// 遵循 Architecture Contract (Section 15 / INV-12)。
/// FreshRSS API Password 必须且仅允许持久化在真实的系统 Keychain 中，
/// 严禁存入 SQLite、UserDefaults、日志或错误消息。
public protocol CredentialStore: Sendable {
    func freshRSSPassword(accountID: String) throws -> String?
    func saveFreshRSSPassword(_ password: String, accountID: String) throws
    func deleteFreshRSSCredentials(accountID: String) throws
}

public enum KeychainError: LocalizedError, Sendable {
    case unhandledError(status: OSStatus)
    case unexpectedDataFormat

    public var errorDescription: String? {
        switch self {
        case let .unhandledError(status):
            return "Keychain error: \(status)"
        case .unexpectedDataFormat:
            return "Keychain returned data in unexpected format."
        }
    }
}

/// 基于 macOS / iOS `Security.framework` 的真实 Keychain 凭据持久化实现。
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let shared = KeychainCredentialStore()

    public let service: String

    public init(service: String = "com.paperrss.freshrss") {
        self.service = service
    }

    public func freshRSSPassword(accountID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedDataFormat
        }
        return password
    }

    public func saveFreshRSSPassword(_ password: String, accountID: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func deleteFreshRSSCredentials(accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}

/// 内存版凭据存储（主要用于单元测试与测试环境隔离）。
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(initialCredentials: [String: String] = [:]) {
        self.storage = initialCredentials
    }

    public func freshRSSPassword(accountID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountID]
    }

    public func saveFreshRSSPassword(_ password: String, accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = password
    }

    public func deleteFreshRSSCredentials(accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}
