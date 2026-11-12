import Foundation

public enum ICloudRecordZone: String, Codable, Sendable, CaseIterable {
    case library = "PaperRssLibrary-v1"
    case articles = "PaperRssArticles-v1"
}

/// Wire records may include content and settings; the lightweight structural
/// and state journal deliberately keeps its original five kinds.
public enum ICloudRecordKind: String, Codable, Sendable {
    case feed, folder, membership, read, starred, content, settings, retention, retentionPolicy, retentionQuota
    var zone: ICloudRecordZone {
        switch self {
        case .read, .starred, .content, .retention, .retentionPolicy, .retentionQuota: .articles
        default: .library
        }
    }
}

public struct ICloudFieldVersion: Codable, Sendable, Equatable, Comparable {
    public let counter: Int64
    public let deviceID: String

    public init(counter: Int64, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }
    public static let bootstrap = Self(counter: 0, deviceID: "")
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}

public enum ICloudFieldValue: Codable, Sendable, Equatable {
    case text(String), integer(Int64), flag(Bool), null
}

public struct ICloudVersionedField: Codable, Sendable, Equatable {
    public let value: ICloudFieldValue
    public let version: ICloudFieldVersion
    public init(value: ICloudFieldValue, version: ICloudFieldVersion) {
        self.value = value
        self.version = version
    }
}

public enum ICloudRecordError: Error, Equatable, Sendable {
    case malformedRecord, unsupportedVersion, identityMismatch, incompatibleRecord
    case unavailableScope, accountChanged, recoveryRequired, persistenceFailed
}

/// Enough original feed information to materialize a reader row without RSS
/// still carrying the item. Summaries and HTML remain behind the body policy.
public struct ICloudArticleMetadata: Codable, Sendable, Equatable {
    public let title: String
    public let author: String?
    public let url: String?
    public let publishedAt: Double?

    init(_ article: ArticleRecord) {
        title = Self.bounded(article.title, bytes: 8192)
        author = article.author.map { Self.bounded($0, bytes: 2048) }
        url = article.url.flatMap { $0.utf8.count <= 8192 ? $0 : nil }
        publishedAt = article.publishedAt?.isFinite == true ? article.publishedAt : nil
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        var result = "", count = 0
        for scalar in value.unicodeScalars {
            let size = scalar.utf8.count
            guard count + size <= bytes else { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }

    func validate() throws {
        guard title.utf8.count <= 8192, (author?.utf8.count ?? 0) <= 2048,
              (url?.utf8.count ?? 0) <= 8192, publishedAt?.isFinite != false else {
            throw ICloudRecordError.malformedRecord
        }
    }

    /// This is a gap-filling snapshot, independent of the user's state clock.
    /// A deterministic tie-break makes differing RSS snapshots converge too.
    func merged(with other: Self) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).lexicographicallyPrecedes(encoder.encode(other)) ? self : other
    }
}

/// Strict portable wire contract. No local item IDs, AI artifacts or caches.
/// read/starred use separate records so an independent change cannot overwrite
/// the other field. Structure fields retain their own logical versions.
public struct ICloudRecordEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: ICloudRecordKind
    public let recordName: String
    public let feedURL: String?
    public let sourceItemID: String?
    public let feedRecordName: String?
    public let folderRecordName: String?
    public var articleMetadata: ICloudArticleMetadata?
    public var fields: [String: ICloudVersionedField]

    public var zone: ICloudRecordZone { kind.zone }

    public init(
        kind: ICloudRecordKind, recordName: String, feedURL: String? = nil,
        sourceItemID: String? = nil, feedRecordName: String? = nil,
        folderRecordName: String? = nil, fields: [String: ICloudVersionedField],
        articleMetadata: ICloudArticleMetadata? = nil
    ) throws {
        schemaVersion = 1
        self.kind = kind; self.recordName = recordName; self.feedURL = feedURL
        self.sourceItemID = sourceItemID; self.feedRecordName = feedRecordName
        self.folderRecordName = folderRecordName; self.fields = fields
        self.articleMetadata = articleMetadata
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ICloudRecordError.unsupportedVersion }
        if let articleMetadata {
            guard kind == .read else { throw ICloudRecordError.malformedRecord }
            try articleMetadata.validate()
        }
        let allowed: Set<String>
        switch kind {
        case .feed: allowed = ["feed_url", "title", "site_url", "sort_order", "deleted"]
        case .folder: allowed = ["name", "sort_order", "deleted"]
        case .membership: allowed = ["deleted"]
        case .read, .starred: allowed = ["value"]
        case .content: allowed = ["payload_hash"]
        case .settings: allowed = ["sync_unread_content"]
        case .retention: allowed = ["read_floor", "starred_floor", "content_floor", "writer_nonce"]
        case .retentionPolicy: allowed = ["protect_unread", "release_unread", "writer_nonce"]
        case .retentionQuota: allowed = ["ledger"]
        }
        guard Set(fields.keys) == allowed,
              fields.values.allSatisfy({ $0.version.counter >= 0 &&
                  ($0.version.counter == 0 ? $0.version.deviceID.isEmpty : UUID(uuidString: $0.version.deviceID) != nil) })
        else { throw ICloudRecordError.malformedRecord }
        for (key, field) in fields {
            switch (key, field.value) {
            case ("deleted", .flag), ("value", .flag), ("sync_unread_content", .flag), ("sort_order", .integer),
                 ("feed_url", .text), ("title", .text), ("name", .text),
                 ("site_url", .text), ("site_url", .null), ("payload_hash", .text), ("payload_hash", .null): break
            case ("ledger", .text(let text)): _ = try ICloudRetentionQuota.decode(text)
            case ("writer_nonce", .text(let nonce)):
                guard field.version == .bootstrap, nonce.isEmpty || UUID(uuidString: nonce)?.uuidString == nonce else {
                    throw ICloudRecordError.malformedRecord
                }
            case ("read_floor", .flag), ("starred_floor", .flag), ("content_floor", .flag),
                 ("protect_unread", .flag), ("release_unread", .flag):
                guard field.value == .flag(true) || field.version == .bootstrap else {
                    throw ICloudRecordError.malformedRecord
                }
            default: throw ICloudRecordError.malformedRecord
            }
        }
        switch kind {
        case .feed:
            guard let feedURL, let url = URL(string: feedURL),
                  try ICloudSyncIdentity.canonicalFeedURL(url) == feedURL,
                  try ICloudSyncIdentity.feedRecordName(feedURL: url) == recordName,
                  fields["feed_url"]?.value == .text(feedURL),
                  sourceItemID == nil, feedRecordName == nil, folderRecordName == nil
            else { throw ICloudRecordError.identityMismatch }
        case .folder:
            guard recordName.hasPrefix("folder-v1:"),
                  UUID(uuidString: String(recordName.dropFirst("folder-v1:".count))) != nil,
                  feedURL == nil, sourceItemID == nil, feedRecordName == nil, folderRecordName == nil
            else { throw ICloudRecordError.identityMismatch }
        case .membership:
            guard let feedRecordName, let folderRecordName,
                  feedRecordName.hasPrefix("feed-v1:"), folderRecordName.hasPrefix("folder-v1:"),
                  ICloudSyncIdentity.membershipRecordName(feedRecordName: feedRecordName, folderRecordName: folderRecordName) == recordName,
                  feedURL == nil, sourceItemID == nil
            else { throw ICloudRecordError.identityMismatch }
        case .read, .starred, .content:
            guard let feedURL, let url = URL(string: feedURL),
                  try ICloudSyncIdentity.canonicalFeedURL(url) == feedURL,
                  let article = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: sourceItemID),
                  recordName == "\(kind.rawValue)-v1:" + article.dropFirst("article-v1:".count),
                  feedRecordName == nil, folderRecordName == nil
            else { throw ICloudRecordError.identityMismatch }
            if kind == .content, case .text(let hash) = fields["payload_hash"]?.value {
                guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) })
                else { throw ICloudRecordError.malformedRecord }
            }
        case .settings:
            guard recordName == "settings-v1:library", feedURL == nil, sourceItemID == nil,
                  feedRecordName == nil, folderRecordName == nil else { throw ICloudRecordError.identityMismatch }
        case .retention:
            guard Self.isHashName(recordName, prefix: "retention-v1:"),
                  let feedRecordName, Self.isHashName(feedRecordName, prefix: "feed-v1:"),
                  feedURL == nil, sourceItemID == nil, folderRecordName == nil else {
                throw ICloudRecordError.identityMismatch
            }
        case .retentionQuota:
            guard recordName == ICloudRetentionQuota.recordName, feedURL == nil, sourceItemID == nil,
                  feedRecordName == nil, folderRecordName == nil else { throw ICloudRecordError.identityMismatch }
        case .retentionPolicy:
            guard recordName == ICloudRetentionUnreadPolicy.recordName, feedURL == nil, sourceItemID == nil,
                  feedRecordName == nil, folderRecordName == nil else { throw ICloudRecordError.identityMismatch }
        }
    }

    public func merged(with other: Self) throws -> Self {
        try validate(); try other.validate()
        guard kind == other.kind, recordName == other.recordName, feedURL == other.feedURL,
              sourceItemID == other.sourceItemID, feedRecordName == other.feedRecordName,
              folderRecordName == other.folderRecordName else { throw ICloudRecordError.incompatibleRecord }
        var result = self
        if let incoming = other.articleMetadata {
            result.articleMetadata = try articleMetadata?.merged(with: incoming) ?? incoming
        }
        for (key, incoming) in other.fields {
            guard let local = fields[key] else { throw ICloudRecordError.malformedRecord }
            if (kind == .retention || kind == .retentionPolicy), key == "writer_nonce" {
                if incoming.value == .text("") { continue }
                result.fields[key] = incoming
                continue
            }
            if kind == .retention || kind == .retentionPolicy {
                // An unset floor is lower than a retired bootstrap version.
                // Unlike user intents, equal bootstrap versions merge by OR.
                if incoming.value == .flag(true), local.value == .flag(false) || local.version < incoming.version {
                    result.fields[key] = incoming
                }
                continue
            }
            if local.version < incoming.version {
                result.fields[key] = incoming
            } else if local.version == incoming.version && local.value != incoming.value {
                // Same device and logical version must identify one immutable intent.
                throw ICloudRecordError.malformedRecord
            }
        }
        return result
    }

    func stampedRetentionSave() throws -> Self {
        try validate()
        guard kind == .retention || kind == .retentionPolicy else { throw ICloudRecordError.malformedRecord }
        var value = self
        value.fields["writer_nonce"] = .init(value: .text(UUID().uuidString), version: .bootstrap)
        return value
    }

    private static func isHashName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let hash = name.dropFirst(prefix.count)
        return hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
