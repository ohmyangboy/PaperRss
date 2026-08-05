@preconcurrency import CloudKit
import Foundation
import Security

public enum CloudSyncError: LocalizedError, Equatable, Sendable {
    case notEntitled

    public var errorDescription: String? {
        "此构建未启用 iCloud 权限：请使用开发者证书签名并在 Xcode 中开启 CloudKit capability。"
    }
}

public struct CloudLibrary: Codable, Sendable {
    public var feeds: [Feed]
    public var readingStates: [String: ReadingState]
    public var artifacts: [AIArtifact]

    public init(feeds: [Feed], readingStates: [String: ReadingState], artifacts: [AIArtifact]) {
        self.feeds = feeds
        self.readingStates = readingStates
        self.artifacts = artifacts
    }

    static func from(_ database: AppDatabase) -> CloudLibrary {
        let states = database.readingStates.isEmpty ? Dictionary(uniqueKeysWithValues: database.entries.map { ($0.id, ReadingState(entryID: $0.id, isRead: $0.isRead, isStarred: $0.isStarred, updatedAt: $0.updatedAt)) }) : database.readingStates
        return CloudLibrary(feeds: database.feeds, readingStates: states, artifacts: database.artifacts)
    }

    static func merged(local: CloudLibrary, remote: CloudLibrary) -> CloudLibrary {
        func merge<T: Identifiable>(_ left: [T], _ right: [T], updatedAt: (T) -> Date) -> [T] where T.ID: Hashable {
            var values = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
            for item in right where values[item.id].map({ updatedAt(item) > updatedAt($0) }) ?? true { values[item.id] = item }
            return Array(values.values)
        }
        var states = local.readingStates
        for (id, remoteState) in remote.readingStates where states[id].map({ remoteState.updatedAt > $0.updatedAt }) ?? true { states[id] = remoteState }
        return CloudLibrary(feeds: merge(local.feeds, remote.feeds, updatedAt: \.updatedAt), readingStates: states, artifacts: merge(local.artifacts, remote.artifacts, updatedAt: \.updatedAt))
    }
}

public actor CloudSyncService {
    public static let shared = CloudSyncService()
    private let recordID = CKRecord.ID(recordName: "paper-rss-library-v1")

    /// Whether the running binary actually carries the CloudKit iCloud
    /// entitlement. Calling `CKContainer.default()` without it raises an
    /// Objective-C exception that Swift cannot catch and aborts the app
    /// (SIGABRT). Ad-hoc signed builds and plain SPM executables never carry
    /// the entitlement, so every CloudKit entry point must check this first
    /// instead of letting the framework throw.
    public static var isICloudEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil),
              let services = value as? [String] else { return false }
        return services.contains("CloudKit")
        #else
        // SecTask is macOS-only, and iOS cannot query its runtime
        // entitlements. iOS is not a release target for now, so keep sync
        // disabled there until a real entitlement path (developer signing +
        // iCloud capability) exists for it.
        return false
        #endif
    }

    public func synchronize(_ local: CloudLibrary) async throws -> CloudLibrary {
        guard Self.isICloudEntitled else { throw CloudSyncError.notEntitled }
        let remote = try await download() ?? CloudLibrary(feeds: [], readingStates: [:], artifacts: [])
        let merged = CloudLibrary.merged(local: local, remote: remote)
        try await upload(merged)
        return merged
    }

    private var database: CKDatabase { CKContainer.default().privateCloudDatabase }

    private func download() async throws -> CloudLibrary? {
        let record: CKRecord? = try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let error = error as? CKError, error.code == .unknownItem { continuation.resume(returning: nil) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: record) }
            }
        }
        guard let asset = record?["payload"] as? CKAsset, let url = asset.fileURL else { return nil }
        return try JSONDecoder.paperRss.decode(CloudLibrary.self, from: Data(contentsOf: url))
    }

    private func upload(_ library: CloudLibrary) async throws {
        let data = try JSONEncoder.paperRss.encode(library)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paper-rss-cloud-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let record = CKRecord(recordType: "PaperRssLibrary", recordID: recordID)
        record["payload"] = CKAsset(fileURL: url)
        _ = try await withCheckedThrowingContinuation { continuation in
            database.save(record) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        } as Void
    }
}
