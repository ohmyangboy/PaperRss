import XCTest
@testable import PaperRssCore

/// 刷新进度的发布次数与可观测性由 `AppStore` 统一负责，节流状态不能跨轮残留。
final class RefreshProgressPublicationTests: XCTestCase {
    @MainActor
    private func makeStore(feedCount: Int, fetchDelay: Duration) -> AppStore {
        let feeds = (0..<feedCount).map { index in
            Feed(id: UUID(), title: "Feed \(index)", feedURL: URL(string: "https://f\(index).example/feed.xml")!)
        }
        let database = AppDatabase(
            feeds: feeds,
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default
        )
        return AppStore(testDatabase: database) { _ in
            try? await Task.sleep(for: fetchDelay)
            return .updated(
                ParsedFeed(
                    title: "Updated",
                    siteURL: nil,
                    iconURL: nil,
                    entries: (0..<3).map { itemIndex in
                        ParsedFeedEntry(
                            id: "item-\(itemIndex)",
                            title: "Article \(itemIndex)",
                            author: nil,
                            url: nil,
                            publishedAt: Date(),
                            summary: "Summary",
                            contentHTML: "<p>Content</p>"
                        )
                    }
                ),
                etag: nil,
                lastModified: nil
            )
        }
    }

    /// 刷新期间 `local-default` 发布过的中间进度（0 < completed < total）。
    @MainActor
    private func observeIntermediateProgress(_ store: AppStore, during body: () async -> Void) async -> [Int] {
        final class Recorder { var values: [Int] = [] }
        let recorder = Recorder()
        let cancellable = store.objectWillChange.sink { _ in
            guard let progress = store.accountRefreshProgress["local-default"],
                  let total = progress.total,
                  progress.completed > 0, progress.completed < total else { return }
            recorder.values.append(progress.completed)
        }
        defer { cancellable.cancel() }
        await body()
        return recorder.values
    }

    /// 上一轮的发布数量不能让下一轮整轮进度都卡在旧进度条上。
    /// 回归对象：每轮刷新的进度节流状态必须从零开始。
    @MainActor
    func testSecondLocalRefreshStillShowsIntermediateProgress() async {
        let store = makeStore(feedCount: 60, fetchDelay: .milliseconds(60))

        let firstRound = await observeIntermediateProgress(store) {
            await store.refresh(origin: .manual)
        }
        let secondRound = await observeIntermediateProgress(store) {
            await store.refresh(origin: .manual)
        }

        XCTAssertFalse(firstRound.isEmpty, "第一轮必须发布中间进度，实际 \(firstRound)")
        XCTAssertFalse(
            secondRound.isEmpty,
            "第二轮也必须发布中间进度，而不是整轮停在旧进度条上，实际 \(secondRound)"
        )
    }

    /// 一轮结束必须撤下进度，否则侧栏会一直显示上一轮的总量。
    @MainActor
    func testCompletedRefreshClearsProgressState() async {
        let store = makeStore(feedCount: 5, fetchDelay: .milliseconds(1))
        await store.refresh(origin: .manual)
        XCTAssertNil(store.accountRefreshProgress["local-default"], "刷新结束后 local-default 的进度必须撤下")
    }
}
