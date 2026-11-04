import XCTest
@testable import PaperRssCore

final class RefreshProgressPublishPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// 每个完成事件都比上一步慢很多（模拟慢机器 / 慢 Feed）。
    /// 数量门槛必须主导发布次数，否则 300 个 Feed 会变成 300 次全局重绘。
    func testCountThresholdBoundsPublishedIntermediatesOnSlowMachine() {
        var policy = RefreshProgressPublishPolicy()
        var publishes = 0
        for completed in 0...300 {
            if policy.shouldPublish(
                AccountRefreshProgress(completed: completed, total: 300),
                at: start.addingTimeInterval(Double(completed) * 0.045)
            ) {
                publishes += 1
            }
        }
        XCTAssertLessThanOrEqual(publishes, 18, "300 个 Feed 的中间进度应合并到约 15 次，实际 \(publishes) 次")
        XCTAssertGreaterThanOrEqual(publishes, 10, "进度仍应随批次推进，而不是只在首尾各发布一次")
    }

    /// 极慢的刷新不能让进度条长时间停在旧值：超过最长等待就必须发布一次。
    func testSlowRefreshStillPublishesWithinMaximumInterval() {
        var policy = RefreshProgressPublishPolicy()
        var publishedAt = [Date]()
        var lastPublishedStep = 0
        for completed in 0...40 {
            let now = start.addingTimeInterval(Double(completed) * 5)  // 每个 Feed 5 秒
            if policy.shouldPublish(AccountRefreshProgress(completed: completed, total: 40), at: now) {
                publishedAt.append(now)
                lastPublishedStep = completed
            }
        }
        XCTAssertGreaterThan(lastPublishedStep, 0, "慢刷新也必须产生中间进度")
        for (previous, next) in zip(publishedAt, publishedAt.dropFirst()) {
            XCTAssertLessThanOrEqual(
                next.timeIntervalSince(previous),
                RefreshProgressPublishPolicy.maximumInterval + 5.0,
                "两次发布之间的间隔不能超过最长等待加一个完成事件"
            )
        }
    }

    /// 新一轮刷新必须从零重新计数。沿用上一轮的数量会让整轮中间进度被吞掉。
    func testSecondRoundPublishesProgressAfterFirstRoundFinished() {
        var firstRound = RefreshProgressPublishPolicy()
        _ = firstRound.shouldPublish(AccountRefreshProgress(completed: 0, total: 300), at: start)
        for completed in stride(from: 20, through: 280, by: 20) {
            _ = firstRound.shouldPublish(
                AccountRefreshProgress(completed: completed, total: 300),
                at: start.addingTimeInterval(Double(completed))
            )
        }
        _ = firstRound.shouldPublish(AccountRefreshProgress(completed: 300, total: 300), at: start.addingTimeInterval(301))

        // 第二轮由 AppStore 重新创建策略值，最早的中间进度必须立刻发布。
        var secondRound = RefreshProgressPublishPolicy()
        let now = start.addingTimeInterval(600)
        XCTAssertTrue(secondRound.shouldPublish(AccountRefreshProgress(completed: 1, total: 300), at: now),
                      "新一轮的第一个进度不能被上一轮的数量门槛挡住")
    }

    /// 同一批次内的连续进度不应重复发布，否则一个 Feed 的多次回调就会各刷一次。
    func testMinimumIntervalSuppressesBurstWithinOneBatch() {
        var policy = RefreshProgressPublishPolicy()
        let now = start
        XCTAssertTrue(policy.shouldPublish(AccountRefreshProgress(completed: 0, total: 300), at: now))
        XCTAssertFalse(policy.shouldPublish(AccountRefreshProgress(completed: 20, total: 300),
                                            at: now.addingTimeInterval(0.05)))
        XCTAssertTrue(policy.shouldPublish(AccountRefreshProgress(completed: 20, total: 300),
                                           at: now.addingTimeInterval(RefreshProgressPublishPolicy.minimumInterval + 0.05)))
    }

    /// 数量回落、总量变化或阶段切换都说明进入了新一轮，必须重新发布。
    func testRestartedOrChangedProgressPublishesImmediately() {
        var policy = RefreshProgressPublishPolicy()
        let now = start
        _ = policy.shouldPublish(AccountRefreshProgress(completed: 200, total: 300), at: now)
        XCTAssertTrue(
            policy.shouldPublish(AccountRefreshProgress(completed: 1, total: 300), at: now.addingTimeInterval(0.1)),
            "数量回落到新一轮起点时必须发布"
        )
        _ = policy.shouldPublish(AccountRefreshProgress(completed: 200, total: 300), at: now.addingTimeInterval(1))
        XCTAssertTrue(
            policy.shouldPublish(AccountRefreshProgress(completed: 201, total: 900), at: now.addingTimeInterval(1.1)),
            "总量改变意味着新的进度序列"
        )
        XCTAssertTrue(
            policy.shouldPublish(AccountRefreshProgress(completed: 202, total: 900, phase: .reconciling),
                                 at: now.addingTimeInterval(1.2)),
            "阶段切换必须立即反映"
        )
    }
}
