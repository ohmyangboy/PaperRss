import Foundation
import PaperRssAITransfer

/// A read-only projection of one account's subscriptions. It contains no article
/// state, remote-account login credentials or AI settings.
public enum SubscriptionTransferSnapshot {
    public static func make(
        accountID: String,
        feedsByAccount: [String: [Feed]],
        foldersByAccount: [String: [String]],
        sourceID: String,
        sourceName: String,
        accountName: String
    ) -> SubscriptionSnapshot {
        var items: [SubscriptionItem] = []
        var itemIndices: [UUID: Int] = [:]
        var allFolders: [String] = []
        var knownFolders = Set<String>()
        func retainFolder(_ folder: String?) -> String? {
            guard let folder, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if knownFolders.insert(folder).inserted { allFolders.append(folder) }
            return folder
        }
        for folder in foldersByAccount[accountID] ?? [] { _ = retainFolder(folder) }
        for feed in feedsByAccount[accountID] ?? [] where !feed.isDeleted {
            let folder = retainFolder(feed.folder)
            if let index = itemIndices[feed.id] {
                let existing = items[index]
                var memberships = existing.folders
                if let folder, !memberships.contains(folder) { memberships.append(folder) }
                items[index] = SubscriptionItem(
                    id: existing.id, title: existing.title, url: existing.url,
                    folder: existing.folder ?? folder, folders: memberships
                )
            } else {
                let customTitle = feed.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = customTitle?.isEmpty == false ? (feed.customTitle ?? feed.title) : feed.title
                itemIndices[feed.id] = items.count
                // Keep the URL unchanged. The receiving preview classifies unsupported
                // or credential-bearing URLs instead of silently losing an entry here.
                items.append(SubscriptionItem(
                    id: feed.id.uuidString, title: title, url: feed.feedURL.absoluteString,
                    folder: folder, folders: folder.map { [$0] } ?? []
                ))
            }
        }
        return SubscriptionSnapshot(sourceID: sourceID, sourceName: sourceName,
                                    accountName: accountName, feeds: items, folders: allFolders)
    }
}
