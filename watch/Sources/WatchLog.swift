import Foundation

// 客户端日志：ring buffer 最近 80 行，内存 + UserDefaults 持久化（app 被杀重启仍在）。
// 随每次 POST 上行到服务端 data/watch_client_logs.log——挂起时段的日志由下一次
// 成功 POST 带出，ssh 直查，不用瞎猜。
enum WatchLog {
    private static let key = "st.watchlog"
    private static let cap = 80
    private static let lock = NSLock()
    private static var lines: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append("[\(fmt.string(from: Date()))] \(line)")
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static func dump() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

// 超时竞速：body 在 seconds 内不返回 → 整体返回 nil（调用方放弃等）。
// 实现要点：不用 TaskGroup——group 退出必须等所有 child 完成，body 若挂死在
// HK 查询上，group 自己也会被拖死。这里 body 跑在独立 Task，超时只 resume
// 等待方；body 挂死就挂着，由 HealthCollector 的 30s 查询兜底自行收尾。
// 后台被系统挂起时 Task.sleep 走连续时钟——下次唤醒恢复时睡债已到期，
// 竞速立刻收场，保证 WKApplicationRefreshBackgroundTask 必完成。
private final class TimeoutGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T?, Never>?
    private var result: T?
    private var done = false

    func awaitResult() async -> T? {
        await withCheckedContinuation { cont in
            lock.lock()
            if done {
                let r = result
                lock.unlock()
                cont.resume(returning: r)
            } else {
                self.cont = cont
                lock.unlock()
            }
        }
    }

    func finish(_ r: T?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        result = r
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: r)
    }
}

func withTimeout<T>(_ seconds: Double, _ body: @escaping () async -> T?) async -> T? {
    let gate = TimeoutGate<T>()
    Task {
        let r = await body()
        gate.finish(r)
    }
    Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        gate.finish(nil)
    }
    return await gate.awaitResult()
}
