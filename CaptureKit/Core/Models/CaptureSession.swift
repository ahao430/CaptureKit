import Foundation

/// 截图确认后的交付动作。
enum CaptureDeliveryAction: CustomStringConvertible {
    /// 复制到剪贴板（默认，Enter / 工具栏「复制」）
    case copy
    /// 直接弹出保存面板
    case save
    /// 进入编辑器（工具栏「编辑」）
    case edit

    var description: String {
        switch self {
        case .copy: return "copy"
        case .save: return "save"
        case .edit: return "edit"
        }
    }
}

/// 截图模式（plan.md §2.3.1 子集，Phase 0 仅启用前三种）。
enum CaptureMode: String, Codable, CaseIterable {
    case region
    case fullscreen
    case window

    var displayName: String {
        switch self {
        case .region: return "区域截图"
        case .fullscreen: return "全屏截图"
        case .window: return "窗口截图"
        }
    }
}

/// 一次截图会话的状态（design.md §6.2）。
struct CaptureSession {
    enum State {
        case idle
        case selecting
        case selected
        case capturing
        case completed
        case cancelled
        case failed
    }

    let id: UUID
    let createdAt: Date
    var mode: CaptureMode
    var state: State = .idle
    /// 全局 AppKit 逻辑坐标选区
    var selection: CGRect?

    init(mode: CaptureMode) {
        id = UUID()
        createdAt = Date()
        self.mode = mode
    }
}
