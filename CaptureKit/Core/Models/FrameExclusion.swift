import Foundation

/// GIF 删帧编辑（plan.md §2.6.6 P1）：被排除的时间段（源视频绝对时间轴，秒）。
struct ExcludedRange: Equatable, Codable {
    let start: Double
    let end: Double

    var duration: Double { end - start }

    init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

/// 排除段集合：维持「排序 + 无重叠」不变量；纯函数可单测。
struct FrameExclusions: Equatable, Codable {
    private(set) var ranges: [ExcludedRange] = []

    init(ranges: [ExcludedRange] = []) {
        self.ranges = FrameExclusions.merged(ranges)
    }

    var isEmpty: Bool { ranges.isEmpty }

    var totalExcludedDuration: Double {
        ranges.reduce(0) { $0 + $1.duration }
    }

    /// 合并重叠/相邻（1ms 容差）段，过滤零长段。
    static func merged(_ input: [ExcludedRange]) -> [ExcludedRange] {
        let sorted = input
            .filter { $0.duration > 0.001 }
            .sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }
        var result = [first]
        for range in sorted.dropFirst() {
            let last = result[result.count - 1]
            if range.start <= last.end + 0.001 {
                result[result.count - 1] = ExcludedRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// 时间点是否被排除。
    func isExcluded(_ time: Double) -> Bool {
        ranges.contains { $0.contains(time) }
    }

    /// 命中段下标。
    func index(containing time: Double) -> Int? {
        ranges.firstIndex { $0.contains(time) }
    }

    /// 切换：命中（按中点）→ 移除该段；未命中 → 加入并合并。
    mutating func toggle(_ range: ExcludedRange) {
        let midpoint = (range.start + range.end) / 2
        if let hit = index(containing: midpoint) {
            ranges.remove(at: hit)
        } else {
            ranges = FrameExclusions.merged(ranges + [range])
        }
    }

    /// 裁剪到 [lower, upper] 区间（导出时按裁剪窗口过滤）。
    func clipped(lower: Double, upper: Double) -> FrameExclusions {
        FrameExclusions(ranges: ranges.compactMap { range in
            let start = max(range.start, lower)
            let end = min(range.end, upper)
            guard end - start > 0.001 else { return nil }
            return ExcludedRange(start: start, end: end)
        })
    }
}
