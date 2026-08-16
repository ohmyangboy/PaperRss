import Foundation

/// FreshRSS / Google Reader API 数据传输对象 (DTO)。
///
/// 遵循 Architecture Contract (Section 6 / INV-04, Section 16)。
/// 所有 remote ID (feed ID, item ID, tag/category ID) 必须且只能作为 opaque String 处理。
public struct ReaderAPICategory: Codable, Sendable, Equatable {
    public let id: String
    public let label: String?

    public init(id: String, label: String? = nil) {
        self.id = id
        self.label = label
    }
}

public struct ReaderAPISubscription: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let categories: [ReaderAPICategory]
    public let url: String?
    public let htmlUrl: String?
    public let sortid: String?
    public let firstitemmsec: String?

    public init(
        id: String,
        title: String,
        categories: [ReaderAPICategory] = [],
        url: String? = nil,
        htmlUrl: String? = nil,
        sortid: String? = nil,
        firstitemmsec: String? = nil
    ) {
        self.id = id
        self.title = title
        self.categories = categories
        self.url = url
        self.htmlUrl = htmlUrl
        self.sortid = sortid
        self.firstitemmsec = firstitemmsec
    }
}

public struct ReaderAPISubscriptionListResponse: Codable, Sendable {
    public let subscriptions: [ReaderAPISubscription]

    public init(subscriptions: [ReaderAPISubscription]) {
        self.subscriptions = subscriptions
    }
}

public struct ReaderAPITag: Codable, Sendable, Equatable {
    public let id: String
    public let sortid: String?

    public init(id: String, sortid: String? = nil) {
        self.id = id
        self.sortid = sortid
    }
}

public struct ReaderAPITagListResponse: Codable, Sendable {
    public let tags: [ReaderAPITag]

    public init(tags: [ReaderAPITag]) {
        self.tags = tags
    }
}

public struct ReaderAPIItemRef: Codable, Sendable, Equatable {
    public let id: String
    public let timestampUsec: String?
    public let directStreamIds: [String]?

    public init(id: String, timestampUsec: String? = nil, directStreamIds: [String]? = nil) {
        self.id = id
        self.timestampUsec = timestampUsec
        self.directStreamIds = directStreamIds
    }

    /// 从 id（例如 "tag:google.com,2005:reader/item/0000000000001234" 或 "foo/a/123"）中提取规范的外部标识
    public var canonicalItemRefID: String {
        let prefix = "tag:google.com,2005:reader/item/"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }
}

public struct ReaderAPIStreamItemIDsResponse: Codable, Sendable {
    public let itemRefs: [ReaderAPIItemRef]?
    public let continuation: String?

    public init(itemRefs: [ReaderAPIItemRef]?, continuation: String? = nil) {
        self.itemRefs = itemRefs
        self.continuation = continuation
    }
}

public struct ReaderAPIAlternate: Codable, Sendable, Equatable {
    public let href: String?
    public let type: String?

    public init(href: String?, type: String? = nil) {
        self.href = href
        self.type = type
    }
}

public struct ReaderAPIOrigin: Codable, Sendable, Equatable {
    public let streamId: String?
    public let title: String?
    public let htmlUrl: String?

    public init(streamId: String?, title: String? = nil, htmlUrl: String? = nil) {
        self.streamId = streamId
        self.title = title
        self.htmlUrl = htmlUrl
    }
}

public struct ReaderAPIContent: Codable, Sendable, Equatable {
    public let content: String?

    public init(content: String?) {
        self.content = content
    }
}

public struct ReaderAPIStreamItem: Codable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let published: Double?
    public let updated: Double?
    public let alternate: [ReaderAPIAlternate]?
    public let categories: [String]?
    public let origin: ReaderAPIOrigin?
    public let summary: ReaderAPIContent?
    public let content: ReaderAPIContent?
    public let author: String?

    public init(
        id: String,
        title: String? = nil,
        published: Double? = nil,
        updated: Double? = nil,
        alternate: [ReaderAPIAlternate]? = nil,
        categories: [String]? = nil,
        origin: ReaderAPIOrigin? = nil,
        summary: ReaderAPIContent? = nil,
        content: ReaderAPIContent? = nil,
        author: String? = nil
    ) {
        self.id = id
        self.title = title
        self.published = published
        self.updated = updated
        self.alternate = alternate
        self.categories = categories
        self.origin = origin
        self.summary = summary
        self.content = content
        self.author = author
    }

    /// 从 id（例如 "tag:google.com,2005:reader/item/0000000000001234" 或 "foo/a/123"）中提取规范的外部标识
    public var canonicalItemRefID: String {
        let prefix = "tag:google.com,2005:reader/item/"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }
}

public struct ReaderAPIStreamContentsResponse: Codable, Sendable {
    public let items: [ReaderAPIStreamItem]
    public let continuation: String?

    public init(items: [ReaderAPIStreamItem], continuation: String? = nil) {
        self.items = items
        self.continuation = continuation
    }
}
