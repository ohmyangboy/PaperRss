import Foundation
import Security

/// 凭据命名空间。
///
/// 每个远端服务使用独立的 Keychain service，账号移除与凭据更新互不覆盖。
/// `freshRSS` 的 Keychain service 保持历史命名，升级后无需重新输入密码。
public enum CredentialScope: String, Codable, Hashable, Sendable {
    case freshRSS
    case miniflux

    public var keychainService: String {
        switch self {
        case .freshRSS:
            // 历史命名空间，不得变更，否则已保存的 FreshRSS 凭据将全部失效。
            return "com.paperrss.freshrss"
        case .miniflux:
            return "com.paperrss.miniflux.googlereader"
        }
    }
}

/// 凭据安全持久化抽象协议。
///
/// 遵循 Architecture Contract (Section 15 / INV-12)。
/// 远端 API Password 必须且仅允许持久化在真实的系统 Keychain 中，
/// 严禁存入 SQLite、UserDefaults、日志或错误消息。
public protocol CredentialStore: Sendable {
    func password(for scope: CredentialScope, accountID: String) throws -> String?
    func savePassword(_ password: String, for scope: CredentialScope, accountID: String) throws
    func deleteCredentials(for scope: CredentialScope, accountID: String) throws
}

/// 旧版 FreshRSS 专用调用入口兼容层；实现委托到通用作用域接口。
public extension CredentialStore {
    func freshRSSPassword(accountID: String) throws -> String? {
        try password(for: .freshRSS, accountID: accountID)
    }

    func saveFreshRSSPassword(_ password: String, accountID: String) throws {
        try savePassword(password, for: .freshRSS, accountID: accountID)
    }

    func deleteFreshRSSCredentials(accountID: String) throws {
        try deleteCredentials(for: .freshRSS, accountID: accountID)
    }
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

    public init() {}

    public func password(for scope: CredentialScope, accountID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.keychainService,
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

    public func savePassword(_ password: String, for scope: CredentialScope, accountID: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.keychainService,
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
            if addStatus != errSecSuccess {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func deleteCredentials(for scope: CredentialScope, accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.keychainService,
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

    public init(initialCredentials: [String: String] = [:], scope: CredentialScope = .freshRSS) {
        for (accountID, password) in initialCredentials {
            storage[Self.storageKey(scope: scope, accountID: accountID)] = password
        }
    }

    public func password(for scope: CredentialScope, accountID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.storageKey(scope: scope, accountID: accountID)]
    }

    public func savePassword(_ password: String, for scope: CredentialScope, accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[Self.storageKey(scope: scope, accountID: accountID)] = password
    }

    public func deleteCredentials(for scope: CredentialScope, accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Self.storageKey(scope: scope, accountID: accountID))
    }

    private static func storageKey(scope: CredentialScope, accountID: String) -> String {
        "\(scope.rawValue)::\(accountID)"
    }
}
