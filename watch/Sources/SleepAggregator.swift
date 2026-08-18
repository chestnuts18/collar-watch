import Foundation
import HealthKit

// 睡眠线:锚点增量查询(上次已 settle 的觉 − 1h 重叠)→ 聚合 session → 上报,
// 靠服务端 (type, at) 幂等去重。不走 anchor 前进到最新段:分段分批到达时
// anchor 会把半截觉永久锁死,且睡着时锚点推进会让醒来后只看到半截觉。
// 回笼觉 = 间隔>60min 的新 session = 新的一条,天然覆盖。
enum SleepAggregator {
    static let sessionGap: TimeInterval = 60 * 60
    static let settleTime: TimeInterval = 10 * 60   // 只聚合"停笔"超过 10 分钟的觉,防半截
    static let window: TimeInterval = 30 * 3600     // 查询窗口(最长夜间觉 ~20h,30h 够,48h 太重)
    private static let lastEndKey = "st.sleep.lastEndAt"
    private static let lastAggKey = "st.sleep.lastAggAt"

    static func collect(store: HKHealthStore) async -> [Sample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let now = Date()
        let t0 = now
        let ud = UserDefaults.standard
        let lastEnd = ud.object(forKey: lastEndKey) as? Date
        let lastAgg = ud.object(forKey: lastAggKey) as? Date
        // 锚点增量(2026-08-19):只查"上次最后分段 − 1h 重叠"之后的新段,
        // 48h 全量重查是后台窗口杀手。重叠 1h 防分段晚到漏段。
        let floor = now.addingTimeInterval(-window)
        let start = max(lastEnd?.addingTimeInterval(-3600) ?? floor, floor)
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let rows: [HKCategorySample] = await withCheckedContinuation { cont in
            var resumed = false
            let finish: ([HKCategorySample]) -> Void = { r in
                if !resumed {
                    resumed = true
                    cont.resume(returning: r)
                }
            }
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                     ascending: true)]) { _, rows, _ in
                WatchLog.log("sleep query done rows=\(rows?.count ?? 0) window=\(Int(Date().timeIntervalSince(start))/60)min \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                finish((rows as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
            // 兜底(2026-08-19):与 queryAnchored 同款,挂起 25s 强制收尾
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
                WatchLog.log("sleep query timeout, forced finish")
                finish([])
            }
        }
        if rows.isEmpty, let lastAgg, now.timeIntervalSince(lastAgg) < 15 * 60 {
            WatchLog.log("sleep skip (no new, agg \(Int(now.timeIntervalSince(lastAgg)))s ago)")
            return []
        }
        let (out, settledEnd) = aggregate(rows: rows, now: now)
        // 锚点只前进到"最后已 settle 的觉"——睡着的觉是未 settle 的,锚点推进会把
        // 整觉前半段推出查询窗口,醒来后聚合出半截觉(2026-08-19 修)
        if let settledEnd { ud.set(settledEnd, forKey: lastEndKey) }
        if !out.isEmpty { ud.set(now, forKey: lastAggKey) }
        return out
    }

    static func aggregate(rows: [HKCategorySample], now: Date) -> ([Sample], settledEnd: Date?) {
        // 手表只产 asleep*/awake 分段;inBed 是 iPhone 侧概念,丢掉
        let stages = rows.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
        guard !stages.isEmpty else { return ([], nil) }

        var sessions: [[HKCategorySample]] = []
        var current: [HKCategorySample] = []
        for s in stages {
            if let last = current.last, s.startDate.timeIntervalSince(last.endDate) > sessionGap {
                sessions.append(current); current = []
            }
            current.append(s)
        }
        if !current.isEmpty { sessions.append(current) }

        let iso = ISO8601DateFormatter()
        var out: [Sample] = []
        var settledEnd: Date?
        for session in sessions {
            guard let first = session.first, let last = session.last else { continue }
            guard now.timeIntervalSince(last.endDate) > settleTime else { continue }
            settledEnd = last.endDate
            var dur: [Int: TimeInterval] = [:]
            for s in session {
                dur[s.value, default: 0] += s.endDate.timeIntervalSince(s.startDate)
            }
            func hours(_ v: HKCategoryValueSleepAnalysis) -> Double {
                ((dur[v.rawValue] ?? 0) / 3600 * 1000).rounded() / 1000
            }
            let core = hours(.asleepCore), deep = hours(.asleepDeep), rem = hours(.asleepREM)
            let unspecified = hours(.asleepUnspecified)
            let total = core + deep + rem + unspecified
            guard total > 0 else { continue }
            // 分段时间轴:合并相邻同阶段成块(哪段几点到几点深睡/REM/醒)
            let stageName: [Int: String] = [
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "deep",
                HKCategoryValueSleepAnalysis.asleepCore.rawValue: "core",
                HKCategoryValueSleepAnalysis.asleepREM.rawValue: "rem",
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: "asleep",
                HKCategoryValueSleepAnalysis.awake.rawValue: "awake",
            ]
            var segments: [[String: String]] = []
            for s in session {
                let name = stageName[s.value] ?? "other"
                if var seg = segments.last, seg["stage"] == name,
                   let e = iso.date(from: seg["end"] ?? ""),
                   s.startDate.timeIntervalSince(e) < 60 {
                    seg["end"] = iso.string(from: s.endDate)
                    segments[segments.count - 1] = seg
                } else {
                    segments.append(["stage": name,
                                     "start": iso.string(from: s.startDate),
                                     "end": iso.string(from: s.endDate)])
                }
            }
            out.append(Sample(
                type: "sleep_analysis", value: nil, unit: "hr", at: last.endDate,
                extra: [
                    "totalSleep": total, "core": core, "deep": deep, "rem": rem,
                    "awake": hours(.awake),
                    "sleepStart": iso.string(from: first.startDate),
                    "sleepEnd": iso.string(from: last.endDate),
                    "segments": segments,
                ]))
        }
        return (out, settledEnd)
    }
}
