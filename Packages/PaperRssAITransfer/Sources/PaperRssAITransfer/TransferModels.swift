import Foundation
import Security

/// Keeps all saved Mac fields, including adaptation metadata unknown to this client.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public static func decode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var double: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
}

public enum TransferError: Error, LocalizedError, Sendable, Equatable {
    case invalidCode, expired, unsupportedVersion, invalidSnapshot, tooLarge, noLocalNetwork, connectionFailed, timedOut, alreadyConsumed, wrongPurpose
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "这不是有效的 PaperRss 配置配对码。"
        case .expired: "配对码已过期，请在 Mac 上重新生成。"
        case .unsupportedVersion: "配对版本暂不兼容，请更新两端 PaperRss。"
        case .invalidSnapshot: "配置内容不完整，未导入任何配置。"
        case .tooLarge: "配置超过传输大小限制。"
        case .noLocalNetwork: "未找到可用的局域网地址，请连接 Wi-Fi 或以太网。"
        case .connectionFailed: "无法连接 Mac，请确认两台设备位于同一局域网，并已允许本地网络访问。"
        case .timedOut: "连接超时，请检查局域网后重新扫码。"
        case .alreadyConsumed: "此配对码已使用，请在 Mac 上重新生成。"
        case .wrongPurpose: "此配对码的用途与当前操作不符，请返回对应的导入入口。"
        }
    }
}

/// This value is exclusively for an in-memory, authenticated device transfer.
/// Never persist or log it. Only settings (without credentials) may be saved.
public struct TransferSnapshot: Codable, Sendable {
    public let version: Int
    public let sourceID: String
    public let sourceName: String
    public let settings: JSONValue
    public let credentials: [String: String]

    public init(version: Int = 1, sourceID: String, sourceName: String, settings: JSONValue, credentials: [String: String]) {
        self.version = version; self.sourceID = sourceID; self.sourceName = sourceName
        self.settings = settings; self.credentials = credentials
    }

    public func validate() throws {
        guard version == 1 else { throw TransferError.unsupportedVersion }
        guard !sourceID.isEmpty, sourceID.utf8.count <= 128, sourceName.utf8.count <= 512,
              let providers = settings["providers"]?.array, providers.count <= 256 else { throw TransferError.invalidSnapshot }
        var ids = Set<String>()
        for provider in providers {
            guard let id = provider["id"]?.string, !id.isEmpty, ids.insert(id).inserted,
                  provider["name"]?.string != nil, provider["baseURL"]?.string != nil,
                  provider["models"]?.array != nil else { throw TransferError.invalidSnapshot }
        }
        guard Set(credentials.keys).isSubset(of: ids) else { throw TransferError.invalidSnapshot }
    }
}

public enum TransferPurpose: String, Codable, Sendable {
    case aiConfiguration
    case subscriptions
}

/// Subscription addresses and folder membership only. AI settings and credentials
/// never participate in this value or in its encrypted transfer.
public struct SubscriptionItem: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let url: String
    public let folder: String?
    public let folders: [String]

    public init(id: String, title: String, url: String, folder: String? = nil, folders: [String] = []) {
        self.id = id; self.title = title; self.url = url; self.folder = folder; self.folders = folders
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, folder, folders }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decode(String.self, forKey: .url)
        folder = try values.decodeIfPresent(String.self, forKey: .folder)
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
}

public struct SubscriptionSnapshot: Codable, Sendable, Equatable {
    public let version: Int
    public let sourceID: String
    public let sourceName: String
    public let accountName: String
    public let feeds: [SubscriptionItem]
    public let folders: [String]

    public init(version: Int = 1, sourceID: String, sourceName: String, accountName: String,
                feeds: [SubscriptionItem], folders: [String]) {
        self.version = version; self.sourceID = sourceID; self.sourceName = sourceName
        self.accountName = accountName; self.feeds = feeds; self.folders = folders
    }

    public func validate() throws {
        guard version == 1 else { throw TransferError.unsupportedVersion }
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceID.utf8.count <= 128, sourceName.utf8.count <= 512, accountName.utf8.count <= 512,
              feeds.count <= 10_000, folders.count <= 10_000,
              folders.allSatisfy({ $0.utf8.count <= 4096 }) else { throw TransferError.invalidSnapshot }
        var ids = Set<String>()
        for feed in feeds {
            guard !feed.id.isEmpty, feed.id.utf8.count <= 512, ids.insert(feed.id).inserted,
                  feed.title.utf8.count <= 8192, feed.url.utf8.count <= 16_384,
                  (feed.folder?.utf8.count ?? 0) <= 4096, feed.folders.count <= 10_000,
                  feed.folders.allSatisfy({ $0.utf8.count <= 4096 }) else { throw TransferError.invalidSnapshot }
        }
        // URL validity belongs to each receiving app's preview; a single malformed
        // or HTTP address must not prevent the rest of the subscriptions importing.
        guard try JSONEncoder().encode(self).count <= 1_048_576 else { throw TransferError.tooLarge }
    }
}

/// A short-lived bearer capability. It contains no provider key, but is still secret.
public struct PairingOffer: Codable, Sendable {
    public let version: Int
    public let hosts: [String]
    public let port: UInt16
    public let sessionID: String
    public let secret: Data
    public let expiresAt: Date
    public let purpose: TransferPurpose?
    public var effectivePurpose: TransferPurpose { purpose ?? .aiConfiguration }

    public init(version: Int = 1, hosts: [String], port: UInt16, sessionID: String, secret: Data, expiresAt: Date,
                purpose: TransferPurpose? = nil) {
        self.version = version; self.hosts = hosts; self.port = port
        self.sessionID = sessionID; self.secret = secret; self.expiresAt = expiresAt
        self.purpose = purpose
    }
    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw TransferError.unsupportedVersion }
        guard expiresAt > now else { throw TransferError.expired }
        guard expiresAt.timeIntervalSince(now) <= 180, !hosts.isEmpty, hosts.count <= 8,
              hosts.allSatisfy(Self.isPrivateIPv4), port != 0, secret.count == 32,
              UUID(uuidString: sessionID) != nil else { throw TransferError.invalidCode }
    }
    public func encodedQRCode() throws -> String {
        try validate()
        let value = try JSONEncoder().encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "paperrss-pair://v1/" + value
    }
    public static func parseQRCode(_ value: String) throws -> PairingOffer {
        let prefix = "paperrss-pair://v1/"
        guard value.hasPrefix(prefix), value.utf8.count <= 4096 else { throw TransferError.invalidCode }
        var body = String(value.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body), let offer = try? JSONDecoder().decode(PairingOffer.self, from: data) else { throw TransferError.invalidCode }
        try offer.validate()
        return offer
    }
    public static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let bytes = components.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
}
