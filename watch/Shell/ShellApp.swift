import SwiftUI

// iOS 壳 — 仅承载 Watch bundle 的容器（配对结构要求）。
// 壳本身无功能，装表流程：iPhone Watch app → XuYu健康 → 安装到手表。
@main
struct ShellApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.pink)
                Text("XuYu健康")
                    .font(.headline)
                Text("手表健康上报容器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
