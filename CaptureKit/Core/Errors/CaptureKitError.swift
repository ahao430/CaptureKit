import Foundation

/// 全局错误模型（design.md §16.2）。
/// UI 层负责将其转换为用户可理解的提示，不得直接展示系统原始错误。
enum CaptureKitError: Error {
    case permissionDenied
    case captureFailed(underlying: Error?)
    case recordingFailed(underlying: Error?)
    case invalidSelection
    case clipboardWriteFailed
    case exportFailed(underlying: Error?)
    case storageFailed(underlying: Error?)
    case unsupportedFormat
    case insufficientDiskSpace
    case cancelled

    /// 用户可读的错误描述。
    var userMessage: String {
        switch self {
        case .permissionDenied:
            return "无法捕获屏幕，需要屏幕录制权限。"
        case .captureFailed:
            return "屏幕捕获失败，请重试。"
        case .recordingFailed:
            return "录制失败，请重试。"
        case .invalidSelection:
            return "选区无效，请重新选择。"
        case .clipboardWriteFailed:
            return "写入剪贴板失败。"
        case .exportFailed:
            return "导出失败。"
        case .storageFailed:
            return "文件存储失败。"
        case .unsupportedFormat:
            return "不支持的导出格式。"
        case .insufficientDiskSpace:
            return "磁盘空间不足，请释放空间后重试。"
        case .cancelled:
            return "操作已取消。"
        }
    }
}
