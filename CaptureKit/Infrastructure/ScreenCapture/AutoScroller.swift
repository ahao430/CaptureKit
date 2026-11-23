import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 自动滚动（plan.md §2.5：Phase 3 补全）。
/// CGEvent 滚轮注入需要「辅助功能」权限；未授权时降级为手动滚动。
enum AutoScroller {
    /// 每次注入的滚动像素步长。
    static let stepPixels: CGFloat = 90

    // MARK: - 权限

    /// 辅助功能权限（不弹窗检测）。
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 系统设置 → 辅助功能 面板。
    @MainActor
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 事件构造与注入

    /// 构造向下滚动事件（pixel 单位；wheel1 负值 = 向下滚动）。
    /// - Parameter pixels: 正数 = 向下滚动该像素数。
    static func makeScrollDownEvent(pixels: CGFloat) -> CGEvent? {
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -Int32(pixels),
            wheel2: 0,
            wheel3: 0
        )
    }

    /// AppKit 全局坐标（主屏左下原点）→ CG 全局坐标（主屏左上原点）。
    /// 纯函数可单测；mainScreenHeight = 主屏逻辑高度（frame.origin.y == 0 的屏）。
    static func appKitToCGGlobal(_ point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }

    /// 窗口命中信息（CGWindowList 条目的最小子集；纯函数可单测）。
    struct WindowHit {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// 自前向后找到包含该点的第一个普通窗口（layer 0）的所属进程。
    /// 排除非 0 层级的浮层/面板（含 CaptureKit 自己的控制条与边框）。
    static func ownerPID(at point: CGPoint, windows: [WindowHit], excludingPID: pid_t) -> pid_t? {
        for window in windows {
            guard window.layer == 0, window.pid != excludingPID,
                  window.bounds.width > 1, window.bounds.height > 1,
                  window.bounds.contains(point) else { continue }
            return window.pid
        }
        return nil
    }

    /// 当前屏幕上包含该点的最前普通窗口的所属进程。
    private static func ownerPID(atCGPoint point: CGPoint) -> pid_t? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let hits: [WindowHit] = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let bounds = CGRect(
                x: dict["X"] ?? 0, y: dict["Y"] ?? 0,
                width: dict["Width"] ?? 0, height: dict["Height"] ?? 0
            )
            return WindowHit(pid: pid, layer: layer, bounds: bounds)
        }
        return ownerPID(at: point, windows: hits, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// 在 AppKit 全局坐标处注入一次向下滚动（pixels 为负 = 向上）。
    ///
    /// 必须用 postToPid 直投目标进程：通过 HID 层注入带坐标的事件时，
    /// 系统会把光标挪到该坐标（实测自动滚动时光标每拍被拽回选区中心）。
    /// 直投时坐标只用于对方判断滚哪个视图，光标不动。
    /// 找不到目标进程时回退到当前光标位置注入（不设置坐标 = 不移动光标）。
    static func postScrollDown(pixels: CGFloat, atAppKitPoint point: CGPoint) {
        guard let event = makeScrollDownEvent(pixels: pixels) else { return }
        let mainScreenHeight = NSScreen.screens.first(where: { $0.frame.origin.y == 0 })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cgPoint = appKitToCGGlobal(point, mainScreenHeight: mainScreenHeight)

        if let pid = ownerPID(atCGPoint: cgPoint) {
            event.location = cgPoint
            event.postToPid(pid)
        } else {
            // 回退：沿用事件创建时的当前光标位置（不显式设置 location，避免光标被移动）
            event.post(tap: .cghidEventTap)
        }
    }
}
