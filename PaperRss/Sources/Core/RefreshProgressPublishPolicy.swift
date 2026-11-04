import Foundation

/// 刷新进度的发布节流策略。
///
/// 进度只在落库批次之后才有意义，因此合并以「已完成条目数」为主，墙钟只做最小间隔：
/// 机器越慢，Feed 之间的墙钟间隔越大，纯时间节流会退化成每个 Feed 发布一次。
/// 同时保留最长等待兜底，慢刷新不会长期停在旧进度。
struct RefreshProgressPublishPolicy {
    /// 一轮刷新最多发布约这么多次中间进度。
    static let intermediateStepCount = 15
    /// 两次发布之间的最小间隔，避免同一批次内连续重绘。
    static let minimumInterval: TimeInterval = 0.3
    /// 中间进度的最长间隔：超过则即使数量未达门槛也发布一次。
    static let maximumInterval: TimeInterval = 2.0

    private var publishedCount: Int?
    private var publishedTotal: Int?
    private var publishedPhase: AccountRefreshProgress.Phase?
    private var publishedAt: Date?

    /// 判断本次进度是否需要发布；需要发布时同步推进策略状态。
    mutating func shouldPublish(_ progress: AccountRefreshProgress, at now: Date) -> Bool {
        // 首尾进度必须发布：0 / total 是调用方判断阶段和清理状态的依据。
        if progress.completed == 0 || progress.completed == progress.total {
            record(progress, at: now)
            return true
        }
        guard let publishedCount, let publishedTotal, let publishedPhase, let publishedAt,
              progress.phase == publishedPhase,
              progress.total == publishedTotal,
              progress.completed > publishedCount else {
            // 没有上一轮记录，或数量回落、总量与阶段变化，都说明这是新一轮（或被重置的一轮）。
            record(progress, at: now)
            return true
        }
        let elapsed = now.timeIntervalSince(publishedAt)
        guard elapsed >= Self.minimumInterval else { return false }
        if elapsed >= Self.maximumInterval {
            record(progress, at: now)
            return true
        }
        let step = max((progress.total ?? progress.completed) / Self.intermediateStepCount, 1)
        guard progress.completed - publishedCount >= step else { return false }
        record(progress, at: now)
        return true
    }

    private mutating func record(_ progress: AccountRefreshProgress, at now: Date) {
        publishedCount = progress.completed
        publishedTotal = progress.total
        publishedPhase = progress.phase
        publishedAt = now
    }
}
