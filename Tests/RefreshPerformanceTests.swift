import Combine
import XCTest
@testable import PaperRssCore

@MainActor
private final class MainActorGapRecorder {
    private var lastTick = Date()
    private(set) var maximumGap: TimeInterval = 0

    func tick() {
        let now = Date()
        maximumGap = max(maximumGap, now.timeIntervalSince(lastTick))
        lastTick = now
    }
}

final class RefreshPerformanceTests: XCTestCase {
    @MainActor
    func testThreeHundredFeedRefreshKeepsMainActorResponsive() async {
        let feeds = (0..<300).map { index in
            Feed(
                id: UUID(),
                title: "Feed \(index)",
                feedURL: URL(string: "https://example\(index).com/feed.xml")!
            )
        }
        let database = AppDatabase(
            feeds: feeds,
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default
        )
        let store = AppStore(testDatabase: database) { _ in
            .updated(
                ParsedFeed(
                    title: "Updated",
                    siteURL: nil,
                    iconURL: nil,
                    entries: (0..<20).map { itemIndex in
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
        let recorder = MainActorGapRecorder()
        var changeCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                guard !Task.isCancelled else { return }
                recorder.tick()
            }
        }

        _ = await store.refresh(origin: .manual)
        ticker.cancel()
        _ = await ticker.result

        XCTAssertLessThan(
            recorder.maximumGap,
            0.1,
            "300-feed refresh starved the main actor for \(recorder.maximumGap)s"
        )
        XCTAssertLessThan(
            changeCount,
            100,
            "Refresh emitted too many global AppStore changes: \(changeCount)"
        )
    }

    @MainActor
    func testThreeHundredNotModifiedRefreshKeepsMainActorResponsive() async {
        let feeds = (0..<300).map { index in
            Feed(
                id: UUID(),
                title: "Feed \(index)",
                feedURL: URL(string: "https://not-modified\(index).example/feed.xml")!
            )
        }
        let store = AppStore(testDatabase: AppDatabase(
            feeds: feeds,
            entries: [],
            articleCaches: [:],
            readingStates: [:],
            artifacts: [],
            llmConfiguration: .default
        )) { _ in
            .notModified(etag: nil, lastModified: nil)
        }
        let recorder = MainActorGapRecorder()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                guard !Task.isCancelled else { return }
                recorder.tick()
            }
        }

        _ = await store.refresh(origin: .manual)
        ticker.cancel()
        _ = await ticker.result

        XCTAssertLessThan(
            recorder.maximumGap,
            0.1,
            "300-feed 304 refresh starved the main actor for \(recorder.maximumGap)s"
        )
    }

    @MainActor
    func testThreeHundredFeedOPMLImportKeepsMainActorResponsive() async {
        let outlines = (0..<300).map { index in
            "<outline text=\"Feed \(index)\" xmlUrl=\"https://import\(index).example/feed.xml\" />"
        }.joined()
        let opml = Data("<opml version=\"2.0\"><body>\(outlines)</body></opml>".utf8)
        let store = AppStore(testDatabase: .empty) { _ in
            .notModified(etag: nil, lastModified: nil)
        }
        let recorder = MainActorGapRecorder()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                guard !Task.isCancelled else { return }
                recorder.tick()
            }
        }

        await store.importOPML(opml)
        ticker.cancel()
        _ = await ticker.result

        XCTAssertEqual(store.feeds.count, 300)
        XCTAssertLessThan(
            recorder.maximumGap,
            0.1,
            "300-feed OPML import starved the main actor for \(recorder.maximumGap)s"
        )
    }
}
