import CoreMedia
import Foundation

/// 录制模式（plan.md §2.6.2）：视频与 GIF 共享采集管线，编码器不同。
enum RecordingMode: String, Codable, CaseIterable {
    case video
    case gif

    var displayName: String {
        switch self {
        case .video: return "视频"
        case .gif: return "GIF"
        }
    }

    var defaultFPS: Int {
        switch self {
        case .video: return 30
        case .gif: return 15
        }
    }
}

/// 录制状态（design.md §8.2）。
enum RecordingState: Equatable {
    case idle
    case selecting
    case starting
    case recording
    case paused
    case stopping
    case completed
    case cancelled
    case failed(String?)
}

/// 录制参数。
struct RecordingSettings: Codable, Equatable {
    var fps: Int
    /// GIF 最大输出宽度（plan.md §2.6.4 预设）
    var gifMaxPixelWidth: Int
    /// 是否显示鼠标指针
    var showsCursor: Bool

    static let `default` = RecordingSettings(fps: 30, gifMaxPixelWidth: 720, showsCursor: true)

    enum CodingKeys: String, CodingKey {
        case fps, gifMaxPixelWidth, showsCursor
    }

    init(fps: Int, gifMaxPixelWidth: Int = 720, showsCursor: Bool = true) {
        self.fps = fps
        self.gifMaxPixelWidth = gifMaxPixelWidth
        self.showsCursor = showsCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        gifMaxPixelWidth = try container.decodeIfPresent(Int.self, forKey: .gifMaxPixelWidth) ?? 720
        showsCursor = try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true
    }

    func resolvedFPS(for mode: RecordingMode) -> Int {
        min(60, max(5, fps))
    }
}

/// 一次录制会话。
struct RecordingSession {
    let id: UUID
    let createdAt: Date
    var mode: RecordingMode
    var state: RecordingState = .idle
    var settings: RecordingSettings
    /// 录制区域（全局 AppKit 逻辑坐标；nil = 整屏）
    var regionRect: CGRect?
    var outputURL: URL?
    var startedAt: Date?

    init(mode: RecordingMode, settings: RecordingSettings, regionRect: CGRect? = nil) {
        id = UUID()
        createdAt = Date()
        self.mode = mode
        self.settings = settings
        self.regionRect = regionRect
    }
}

/// 暂停时间轴（design.md §8.3：暂停期间不产出帧；输出 PTS 需要扣除暂停段）。
/// 基于秒的纯值类型，可单测。
struct PauseTimeline: Equatable {
    struct Segment: Equatable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    private(set) var segments: [Segment] = []
    private(set) var pauseStartedAt: Double?

    /// 已结束暂停段的总时长（进行中的暂停不计入，恢复时结算）。
    var totalPausedDuration: Double {
        segments.reduce(0.0) { $0 + $1.duration }
    }

    /// 开始暂停（记录原始时间轴上的时刻，单位秒）。
    mutating func pause(at seconds: Double) {
        guard pauseStartedAt == nil else { return }
        pauseStartedAt = seconds
    }

    /// 结束暂停。
    mutating func resume(at seconds: Double) {
        guard let start = pauseStartedAt else { return }
        if seconds > start {
            segments.append(Segment(start: start, end: seconds))
        }
        pauseStartedAt = nil
    }

    /// 是否处于暂停中。
    var isPaused: Bool { pauseStartedAt != nil }

    /// 暂停中的帧应被丢弃。
    func shouldDropFrame(at seconds: Double) -> Bool {
        if let start = pauseStartedAt, seconds >= start { return true }
        return false
    }

    /// 原始 PTS → 输出 PTS（扣除此前已结束的暂停段）。
    func adjustedPTS(_ rawSeconds: Double) -> Double {
        var offset: Double = 0
        for segment in segments where segment.end <= rawSeconds {
            offset += segment.duration
        }
        return rawSeconds - offset
    }
}
