#if os(iOS)
import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    static let identifier = "com.yangbukun.PaperRss.refresh"

    static func schedule(interval: FeedRefreshInterval) {
        guard let seconds = interval.seconds else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(60 * 15, seconds))
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
