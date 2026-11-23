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

    /// 选区内容像素快照（标注模式马赛克/模糊实时预览的数据源；选区变化时失效）
    var selectionBaseImage: CGImage?

    /// 当前交互/悬停中的全局鼠标点（十字线与放大镜跟随）
    var currentDragPoint: CGPoint?

    /// 取色复制反馈（"已复制 #RRGGBB"），短暂显示后由控制器清除
    var colorCopyFeedback: String?

    // MARK: 选区内直接标注（DingTalk 式，批次 2）

    /// 标注模式：选区内直接绘制，不打开编辑器
    var annotateMode = false
    /// 当前标注工具
    var annotateTool: AnnotationType = .arrow
    /// 当前标注样式（新标注使用）
    var annotateStyle: AnnotationStyle = .default
    /// 已提交的标注（选区本地坐标：原点 = 选区左下角，y 向上）
    var annotations: [Annotation] = []
    /// 拖拽中的草稿标注（提交前实时预览）
    var draftAnnotation: Annotation?
    /// 草稿拖拽起点（选区本地坐标）
    var annotateDragStart: CGPoint?

    var hasSelection: Bool { selection != nil }

    var isInteracting: Bool {
        if case .none = interaction { return false }
        return true
    }

    /// 正在绘制标注草稿（工具栏需要避让）
    var isAnnotateDrafting: Bool { draftAnnotation != nil }

    /// 是否应显示放大镜：
    /// - 创建/调整/移动中（拖拽取色对齐边缘）
    /// - 无选区悬停时（DingTalk 式悬停取色）
    /// 均要求鼠标点与快照可用；标注模式下不显示。
    var showsMagnifier: Bool {
        guard !annotateMode, currentDragPoint != nil, !snapshots.isEmpty else { return false }
        if isInteracting { return true }
        return selection == nil
    }

    /// 供命中的窗口列表（过滤掉无效 frame）。
    func windowFramesNear(_ point: CGPoint) -> [CGRect] {
        windowFrames.filter { $0.width > 1 && $0.height > 1 }
    }
}
