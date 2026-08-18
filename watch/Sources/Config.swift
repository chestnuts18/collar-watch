import Foundation

enum Config {
    static let endpoint = URL(string: "http://192.168.3.218:8080/api/health/watch")!
    static let source = "aion_watch"
    // token 走构建注入（2026-08-19）：仓库转 public 前轮换，明文不再进源码。
    // Info.plist 的 WATCH_HEALTH_TOKEN 由 CI 用 GitHub Secrets 经 $(WATCH_HEALTH_TOKEN) 注入。
    static let token = Bundle.main.object(forInfoDictionaryKey: "WATCH_HEALTH_TOKEN") as? String ?? ""
}
