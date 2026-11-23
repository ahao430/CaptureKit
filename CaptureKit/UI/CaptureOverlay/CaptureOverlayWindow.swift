import AppKit

/// 无边框、透明、可接收键盘事件的 Overlay 窗口。
/// 每个目标显示器一个实例，frame 覆盖整屏。
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
