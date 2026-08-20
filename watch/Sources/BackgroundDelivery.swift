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
                // completion 不能押在 runCycle 链尾(内含 sendSync 同步 POST,最坏 37s):
                // Apple 文档明确 completion 不回 → 系统停止/暂停后台投递。
                // 20s 独立强制兜底 + 线程安全单次调用(2026-08-20 加,对齐 TaskCompleter)。
                let guard_ = CompletionGuard()
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    if guard_.run(completion) {
                        WatchLog.log("observer completion forced \(type.identifier)")
                    }
                }
                Task {
                    await Scheduler.runCycle(foreground: false)
                    if guard_.run(completion) {
                        WatchLog.log("observer completion after cycle \(type.identifier)")
                    }
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

// observer completion 守卫:线程安全、只执行一次。
// run() 返回本次是否真的执行了(供日志区分"正常收尾/强制兜底")。
final class CompletionGuard {
    private var done = false
    private let lock = NSLock()
    func run(_ completion: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        completion()
        return true
    }
}
