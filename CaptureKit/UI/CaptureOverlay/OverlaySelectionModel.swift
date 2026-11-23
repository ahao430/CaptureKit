import AppKit
import CoreGraphics
import Foundation

/// Overlay 期间的屏幕快照（放大镜与内容来源）。
/// 捕获时排除自身窗口（Overlay 不入图）；dismiss 时随模型一并释放。
struct ScreenSnapshot {
    let displayID: CGDirectDisplayID
    /// 显示器全局逻辑 frame
    let frame: CGRect
    let image: CGImage
}

/// Overlay 共享选区模型（AppKit 全局逻辑坐标）。
/// 每屏一个 CaptureOverlayView 共享同一实例，实现跨屏选区绘制。
@MainActor
final class OverlaySelectionModel {
    enum Interaction {
        case none
        /// 正在拖拽创建选区（记录全局起点）
        case creating(start: CGPoint)
        /// 正在移动已有选区（记录全局鼠标点与选区原位置）
        case moving(dragOrigin: CGPoint, selectionOrigin: CGRect)
        /// 正在拖拽控制点调整大小
        case resizing(handle: SelectionHandle)
    }

    /// 当前选区（全局逻辑坐标），nil 表示尚未创建
    var selection: CGRect?
    var interaction: Interaction = .none

    /// 顶部操作提示（无选区时显示）
    var hint: String = ""

    /// 空格按住中（空格 + 拖动 = 移动选区）
    var isSpacePressed = false

    /// 最近一次 mouseDown 的时间与位置，用于双击检测
    var lastClick: (time: Date, point: CGPoint)?

    /// 鼠标悬停窗口 frame（无选区且非交互时高亮）
    var hoverWindowFrame: CGRect?

    /// 各屏内容快照（放大镜数据源，异步就绪）
    var snapshots: [ScreenSnapshot] = []

    /// 可交互窗口 frame 列表（悬停检测 / 单击选中 / 边缘吸附）
    var windowFrames: [CGRect] = []

    /// 当前交互中的全局鼠标点（十字线与放大镜跟随）
    var currentDragPoint: CGPoint?

    var hasSelection: Bool { selection != nil }

    var isInteracting: Bool {
        if case .none = interaction { return false }
        return true
    }

    /// 是否应显示放大镜（创建/调整中且快照可用）。
    var showsMagnifier: Bool {
        guard isInteracting, currentDragPoint != nil, !snapshots.isEmpty else { return false }
        return true
    }

    /// 供命中的窗口列表（过滤掉无效 frame）。
    func windowFramesNear(_ point: CGPoint) -> [CGRect] {
        windowFrames.filter { $0.width > 1 && $0.height > 1 }
    }
}
