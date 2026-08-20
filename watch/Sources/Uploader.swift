import Foundation
import WatchKit

// 上报器。watchOS 后台任务的 CPU 窗口只有几秒,上传必须交给系统的
// background URLSession:任务发起后 app 即可挂起,传输完成时系统用
// WKURLSessionRefreshBackgroundTask 重新拉起 app,由 delegate 收尾。
// 游标协议:发送前持久化待提交游标,HTTP 2xx 才 commit;失败直接丢批,
// 样本躺在健康库里下次重查重传,服务端 (type,at) 幂等兜底。
final class Uploader: NSObject, URLSessionDataDelegate {
    static let shared = Uploader()
    static let sessionID = "com.example.collarwatch.upload"
    private static let pendingKey = "pendingAnchors"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // WKURLSessionRefreshBackgroundTask 的收尾闭包,didComplete 后调用
    var pendingSessionTask: (() -> Void)?

    func send(samples: [Sample], pendingAnchors: [String: Data]) throws {
        WatchLog.log("send \(samples.count) samples")
        guard !samples.isEmpty else {
            // 空批也提交游标:没有新样本时游标照常前进,避免下次重查旧区间
            HealthCollector.commit(anchors: pendingAnchors)
            return
        }
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "source": Config.source,
            "samples": samples.map { $0.asJSON(iso: iso) },
            // 客户端日志随行(2026-08-19):服务端落盘 data/watch_client_logs.log,
            // 挂起时段发生了什么由下一次成功 POST 带出
            "log": WatchLog.dump(),
            // 电量感知(2026-08-20):服务端存最新电量,低电量提醒徐聿、断流告警豁免
            "battery": WKInterfaceDevice.current().batteryLevel,
            "night_watch": WorkoutMeasurer.shared.nightWatchOn,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).json")
        try data.write(to: tmp)

        // 覆盖窗口:后台任务由系统串行调度,与手动触发重叠的概率极小;
        // 即便覆盖也只是丢一次游标提交,下次重查重传,幂等安全。
        UserDefaults.standard.set(pendingAnchors, forKey: Self.pendingKey)

        var req = URLRequest(url: Config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.token, forHTTPHeaderField: "X-Health-Token")
        session.uploadTask(with: req, fromFile: tmp).resume()
        Status.shared.note(sent: samples.count)
    }

    /// 后台任务窗口内的同步上传（2026-08-19）：
    /// background URLSession 在息屏时由系统调度，120s 资源超时经常发不出去
    /// （实测「bg wake urlsession → upload fail 请求超时」——后台唤醒 runCycle
    /// 完整跑完但数据上不去，念宝观察到「手动点开才上传」）。后台任务窗口
    /// （几秒~30s）内 app 不挂起，用共享 session 直接 POST 同步等结果：
    /// 成功 commit anchors；失败留待下次（anchor 不前进，幂等安全）。
    func sendSync(samples: [Sample], pendingAnchors: [String: Data]) async -> Bool {
        guard !samples.isEmpty else {
            HealthCollector.commit(anchors: pendingAnchors)
            return true
        }
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "source": Config.source,
            "samples": samples.map { $0.asJSON(iso: iso) },
            "log": WatchLog.dump(),
            // 电量感知(2026-08-20):同 send()
            "battery": WKInterfaceDevice.current().batteryLevel,
            "night_watch": WorkoutMeasurer.shared.nightWatchOn,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            WatchLog.log("sendSync encode fail")
            return false
        }
        var req = URLRequest(url: Config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.token, forHTTPHeaderField: "X-Health-Token")
        req.timeoutInterval = 15
        req.httpBody = data
        WatchLog.log("sendSync \(samples.count) samples")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let r = resp as? HTTPURLResponse, (200..<300).contains(r.statusCode) {
                HealthCollector.commit(anchors: pendingAnchors)
                Status.shared.note(success: Date())
                WatchLog.log("sendSync ok code=\(r.statusCode)")
                return true
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            Status.shared.note(failure: code, message: nil)
            WatchLog.log("sendSync fail code=\(code)")
        } catch {
            Status.shared.note(failure: 0, message: error.localizedDescription)
            WatchLog.log("sendSync error: \(error.localizedDescription)")
        }
        return false
    }

    // WKURLSessionRefreshBackgroundTask 到来时重建同名会话以接住 delegate 回调
    func reconnectBackgroundSession() { _ = session }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, (200..<300).contains(code) {
            if let anchors = UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: Data] {
                HealthCollector.commit(anchors: anchors)
            }
            Status.shared.note(success: Date())
            WatchLog.log("upload ok code=\(code)")
        } else {
            Status.shared.note(failure: code, message: error?.localizedDescription)
            WatchLog.log("upload fail code=\(code) err=\(error?.localizedDescription ?? "none")")
            // 失败提前重试(2026-08-19):原来只能等 15-35min 下一档,现在约 15min 后再来一次
            Scheduler.scheduleNext()
        }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        cleanupTempFiles()
        DispatchQueue.main.async {
            self.pendingSessionTask?()
            self.pendingSessionTask = nil
        }
    }

    private func cleanupTempFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("upload-")
                          && f.pathExtension == "json" {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
