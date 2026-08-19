import Foundation
import HealthKit

// HK 后台投递(2026-08-20,待办 4):新样本落库即唤醒 app,不依赖 BGAppRefresh 预算。
// BGAppRefresh 被停投时(强制退出/任务未完成罚停),这条链还能续命。
// 唤醒频率仍受系统节制,runCycle 自带 5 分钟防叠加,不会风暴。
final class BackgroundDelivery {
    static let shared = BackgroundDelivery()
    private let store = HealthCollector.shared.store
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        for type in HealthCollector.shared.deliverySampleTypes {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if let error {
                    WatchLog.log("delivery err \(type.identifier): \(error.localizedDescription)")
                    completion()
                    return
                }
                WatchLog.log("bg delivery wake \(type.identifier)")
                Task {
                    await Scheduler.runCycle(foreground: false)
                    completion()
                }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, error in
                WatchLog.log("delivery enable \(type.identifier) ok=\(ok)" +
                             (error.map { " err=\($0.localizedDescription)" } ?? ""))
            }
        }
    }
}
