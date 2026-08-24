import XCTest
@testable import PaperRssCore

private actor RefreshDeletionGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func wait() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func wasReleased() -> Bool {
        released
    }
}

final class RefreshDeletionTests: XCTestCase {
    @MainActor
    func testDeletingFeedDuringRefreshCancelsAndDiscardsItsOperation() async {
        let feed = Feed(
            id: UUID(),
            title: "删除中的 Feed",
            feedURL: URL(string: "https://cancelled.example/feed.xml")!
        )
        let gate = RefreshDeletionGate()
        let store = AppStore(testDatabase: AppDatabase(
            feeds: [feed],
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default
        )) { _ in
            await gate.wait()
            try Task.checkCancellation()
            return .updated(
                ParsedFeed(
                    title: "不应写回的结果",
                    siteURL: nil,
                    iconURL: nil,
                    entries: [
                        ParsedFeedEntry(
                            id: "stale-after-delete",
                            title: "不应出现",
                            author: nil,
                            url: nil,
                            publishedAt: Date(),
                            summary: "",
                            contentHTML: nil
                        )
                    ]
                ),
                etag: nil,
                lastModified: nil
            )
        }

        let refreshTask = Task { @MainActor in
            await store.refresh(origin: .manual)
        }
        await gate.waitUntilEntered()

        store.deleteFeed(feed)
        let cancelledPromptly = await waitUntil(timeout: .milliseconds(250)) {
            !store.isRefreshing
        }
        let wasReleased = await gate.wasReleased()
        XCTAssertTrue(wasReleased, "删除动作没有取消底层 Feed 抓取任务")
        await gate.release()
        _ = await refreshTask.value

        XCTAssertTrue(cancelledPromptly, "删除唯一刷新中的 Feed 后 Loading 不应继续占用刷新生命周期")
        XCTAssertTrue(store.feeds.isEmpty)
        XCTAssertTrue(store.entryListItems.isEmpty, "已删除 Feed 的迟到结果不得写回文章列表")
        XCTAssertEqual(store.latestRefreshOutcome?.failedFeedCount, 0, "已删除 Feed 不应被报告为刷新失败")
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
