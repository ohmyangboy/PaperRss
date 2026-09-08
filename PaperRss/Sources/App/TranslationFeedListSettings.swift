import SwiftUI
#if canImport(PaperRssCore)
import PaperRssCore
#endif

struct TranslationFeedListSettings: View {
    @ObservedObject var store: AppStore
    @State private var showsLists = false
    var body: some View {
        Button(I18N.localized("管理", englishFallback: "Manage")) { showsLists = true }
            .accessibilityIdentifier("translation-manage-lists")
        .sheet(isPresented: $showsLists) { TranslationFeedListsView(store: store) }
    }
}

private struct TranslationFeedChoice: Identifiable {
    let feed: Feed
    let accountID: String
    let accountName: String
    var id: UUID { feed.id }
}

private struct TranslationFeedListsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    private var choices: [TranslationFeedChoice] {
        store.accounts.flatMap { account in
            (store.feedsByAccount[account.id] ?? []).map {
                TranslationFeedChoice(feed: $0, accountID: account.id, accountName: account.displayName)
            }
        }.sorted { $0.feed.title.localizedStandardCompare($1.feed.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(I18N.localized("翻译黑白名单", englishFallback: "Translation feed lists")).font(.title2.bold())
                Spacer()
                Button(I18N.localized("完成", englishFallback: "Done")) { dismiss() }
            }
            Text(I18N.localized("自动翻译开启时：白名单固定翻译，黑名单不自动翻译，其余订阅自动识别。", englishFallback: "When automatic translation is on: always translate whitelisted feeds, skip blacklisted feeds, and detect the language for other feeds."))
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                column(.whitelist)
                Divider()
                column(.blacklist)
            }
            Text(I18N.localized("同一订阅只能加入一个名单；加入另一侧会自动移出原名单。手动翻译不受名单限制。", englishFallback: "A feed can belong to one list. Adding it to the other list moves it. Manual translation remains available."))
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 720, height: 520)
    }
    private func column(_ list: TranslationFeedList) -> some View {
        TranslationFeedListColumn(list: list, choices: choices, memberships: store.translationFeedLists) { choice, value in
            do { try store.setTranslationFeedList(value, feedID: choice.id, accountID: choice.accountID) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct TranslationFeedListColumn: View {
    let list: TranslationFeedList
    let choices: [TranslationFeedChoice]
    let memberships: [UUID: TranslationFeedList]
    let update: (TranslationFeedChoice, TranslationFeedList?) -> Void
    @State private var search = ""
    private var results: [TranslationFeedChoice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return choices.filter {
            query.isEmpty ? memberships[$0.id] == list : $0.feed.title.localizedStandardContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(list.title).font(.headline)
                Text("\(choices.filter { memberships[$0.id] == list }.count)").foregroundStyle(.secondary)
            }
            TextField(I18N.localized("搜索订阅以添加", englishFallback: "Search feeds to add"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("translation-list-search-\(list.rawValue)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(results) { choice in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.feed.title).lineLimit(2)
                                Text(choice.accountName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            let added = memberships[choice.id] == list
                            Button { update(choice, added ? nil : list) } label: {
                                Image(systemName: added ? "minus.circle" : "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .help(I18N.localized(added ? "移出名单" : "加入名单", englishFallback: added ? "Remove from list" : "Add to list"))
                            .accessibilityLabel(I18N.localized(added ? "移出名单" : "加入名单", englishFallback: added ? "Remove from list" : "Add to list") + " · " + choice.feed.title)
                        }
                    }
                    if results.isEmpty {
                        Text(I18N.localized(search.isEmpty ? "搜索并添加订阅" : "没有匹配的订阅", englishFallback: search.isEmpty ? "Search to add a feed" : "No matching feeds"))
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }.padding(.vertical, 4)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TranslationFeedListMenu: View {
    @ObservedObject var store: AppStore
    let feedID: UUID
    let accountID: String

    var body: some View {
        ForEach(TranslationFeedList.allCases, id: \.self) { list in
            let selected = store.translationFeedLists[feedID] == list
            Button {
                do { try store.setTranslationFeedList(selected ? nil : list, feedID: feedID, accountID: accountID) }
                catch { store.reportError(error, module: .settings) }
            } label: {
                Label(title(list, selected: selected), systemImage: selected ? "checkmark" : "character.bubble")
            }
        }
    }

    private func title(_ list: TranslationFeedList, selected: Bool) -> String {
        switch (list, selected) {
        case (.whitelist, false): I18N.localized("加入翻译白名单", englishFallback: "Add to translation whitelist")
        case (.whitelist, true): I18N.localized("移出翻译白名单", englishFallback: "Remove from translation whitelist")
        case (.blacklist, false): I18N.localized("加入翻译黑名单", englishFallback: "Add to translation blacklist")
        case (.blacklist, true): I18N.localized("移出翻译黑名单", englishFallback: "Remove from translation blacklist")
        }
    }
}
