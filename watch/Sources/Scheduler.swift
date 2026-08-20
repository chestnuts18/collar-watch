import Foundation
import WatchKit
import UserNotifications

// 后台刷新链。铁律:每次醒来先预约下一次再干活——采集/上传途中崩溃,
// 链条也不断。预约的 15 分钟是"最早不早于",实际间隔系统按预算给
// (带表盘小组件时最高一刻钟一档)。
enum Scheduler {
    static let interval: TimeInterval = 15 * 60

    static func scheduleNext() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil) { _ in }
    }

    // 指令检查(独立可调):runCycle 开头调,前台轻轮询也调。
    // 前台→直接开 workout session 实测;后台→只发本地通知
    // (watchOS 不允许后台启动 workout session,点通知进 app 即自动开测)。
    static func checkCommand(foreground: Bool) async {
        if let cmd = await CommandFetcher.fetch(),
           cmd.command == "measure_heart_rate",
           let cid = cmd.command_id {
            if foreground {
                let secs = cmd.duration_seconds ?? 30
                await MainActor.run {
                    WorkoutMeasurer.shared.start(commandID: cid, duration: secs)
                }
            } else {
                CommandFetcher.notifyPickup()
            }
        }
    }

    // 一个完整采集上报周期:点测类增量 + 睡眠全量聚合,合批发送。
    // 进门先查指令;无指令→零动作,照旧采集上报。
    //
    // 超时兜底(2026-08-20 收缩):后台任务窗口只有几秒,HK 查询可能被系统挂起不回,
    // 串行链任何一环卡死都会让 POST 发不出去(18:37-20:00「有 GET 无 POST」案)。
    // collect 12s / sleep 10s 竞速,超时放弃该环但不挡上传与收尾——
    // 旧 30s/20s/90s 超出窗口,任务未完成被系统停投(08-19 停投 5h 案)。
    static var lastCycleStart = Date.distantPast

    static func runCycle(foreground: Bool = true, skipCommand: Bool = false) async {
        // 防叠加:5 分钟内刚启动过 → 上一周期可能冻结未死(窗口耗尽被挂起),
        // 别叠新周期;旧周期恢复后自行收尾,或由 handle 的 24s 兜底收割。
        let since = Date().timeIntervalSince(lastCycleStart)
        if since < 300 {
            WatchLog.log("runCycle skip (prev in flight \(Int(since))s)")
            return
        }
        lastCycleStart = Date()
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        WatchLog.log("runCycle begin fg=\(foreground)")

        if !skipCommand {
            await checkCommand(foreground: foreground)
        }

        var samples: [Sample] = []
        var anchors: [String: Data] = [:]
        if let r = await withTimeout(12, { await HealthCollector.shared.collect() }) {
            (samples, anchors) = (r.0, r.1)
            WatchLog.log("collect done n=\(samples.count) \(ms())ms")
        } else {
            WatchLog.log("collect timeout \(ms())ms — abort cycle")
            return
        }

        let sleep: [Sample]
        if let r = await withTimeout(10, { await SleepAggregator.collect(store: HealthCollector.shared.store) }) {
            sleep = r
            WatchLog.log("sleep done n=\(sleep.count) \(ms())ms")
        } else {
            WatchLog.log("sleep timeout \(ms())ms — send without sleep")
            sleep = []
        }

        if foreground {
            do {
                try Uploader.shared.send(samples: samples + sleep, pendingAnchors: anchors)
            } catch {
                Status.shared.note(failure: -1, message: error.localizedDescription)
                WatchLog.log("send error: \(error.localizedDescription)")
            }
        } else {
            // 后台任务窗口内同步上传（2026-08-19）：background URLSession 息屏时
            // 系统调度慢、120s 超时发不出去——窗口内直接 POST 同步等结果
            _ = await Uploader.shared.sendSync(samples: samples + sleep, pendingAnchors: anchors)
        }
        WatchLog.log("runCycle end \(ms())ms")
    }
}

// 后台任务完成器:setTaskCompletedWithSnapshot 只能喊一次(2026-08-20)。
final class TaskCompleter {
    private var done = false
    private let lock = NSLock()
    func complete(_ task: WKRefreshBackgroundTask) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompletedWithSnapshot(false)
    }
}

final class ExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Scheduler.scheduleNext()   // 前台启动重建链,后台链断掉时的自愈入口
        BackgroundDelivery.shared.start()  // HK 后台投递:数据变化即唤醒(2026-08-20)
        // 本地通知授权(后台撞见指令时提醒佩戴者,点通知直接进 app)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Scheduler.scheduleNext()
                Status.shared.noteBackgroundWake(Date())   // 真机验收定时链的观测点
                WatchLog.log("bg wake refresh")
                // 独立兜底(2026-08-20):24s 必喊完成,不押在 runCycle 链尾——
                // 任务未完成系统会停投后续唤醒(08-19 停投 5h 案),进程活着就必须完成。
                let completer = TaskCompleter()
                DispatchQueue.global().asyncAfter(deadline: .now() + 24) {
                    WatchLog.log("bg task forced completed")
                    completer.complete(refresh)
                }
                Task {
                    await withTimeout(24) { await Scheduler.runCycle(foreground: false) }
                    WatchLog.log("bg task completed")
                    completer.complete(refresh)
                }
            case let urlTask as WKURLSessionRefreshBackgroundTask:
                Uploader.shared.pendingSessionTask = {
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
                Uploader.shared.reconnectBackgroundSession()
                WatchLog.log("bg wake urlsession")
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
