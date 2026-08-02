#if os(iOS)
import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    static let identifier = "com.yangbukun.PaperRss.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 45)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
