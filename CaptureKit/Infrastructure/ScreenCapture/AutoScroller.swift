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

    /// 在 AppKit 全局坐标处注入一次向下滚动（事件路由到该位置下的窗口）。
    static func postScrollDown(pixels: CGFloat, atAppKitPoint point: CGPoint) {
        guard let event = makeScrollDownEvent(pixels: pixels) else { return }
        let mainScreenHeight = NSScreen.screens.first(where: { $0.frame.origin.y == 0 })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        event.location = appKitToCGGlobal(point, mainScreenHeight: mainScreenHeight)
        event.post(tap: .cghidEventTap)
    }
}
