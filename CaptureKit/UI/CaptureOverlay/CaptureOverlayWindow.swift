import AppKit

/// 无边框、透明、可接收键盘事件的 Overlay 窗口。
/// 每个目标显示器一个实例，frame 覆盖整屏。
///
/// 必须是 nonactivatingPanel：普通 NSWindow 被点击时会激活应用并把 key window
/// 置顶，导致兄弟窗口（工具栏/模式胶囊）被压到下面再也点不到（实测层序翻转）。
/// 非激活面板点击不触发应用激活，z-order 全程稳定。
final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override init(contentRect: NSRect, styleMask mask: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backingStoreType,
            defer: flag
        )
    }
}
