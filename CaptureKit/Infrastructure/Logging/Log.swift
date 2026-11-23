import OSLog

/// 按 design.md §16.1 定义统一日志分类。
/// 禁止向日志写入剪贴板正文、Token、密码等敏感内容。
enum Log {
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let settings = Logger(subsystem: subsystem, category: "settings")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.wanghao.capturekit"
}
