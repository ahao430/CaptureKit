import AppKit

/// 录制区域边框：录制期间在区域四周显示红色描边。
/// 透明全窗 + 内孔裁剪，不遮挡区域内容与鼠标事件；
/// 录屏流已排除自身 App 窗口（SCContentFilter excludingApplications），不会入镜。
@MainActor
final class RecordingRegionBorderPanel: NSPanel {
    private let borderWidth: CGFloat = 3

    private let color: NSColor

    /// - Parameter color: 边框色（录制 = 红；滚动截图 = 蓝）
    init(region: CGRect, color: NSColor = .systemRed) {
        self.color = color
        let outer = region.insetBy(dx: -borderWidth, dy: -borderWidth)
        super.init(
            contentRect: outer,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrameOrigin(outer.origin)

        let view = BorderView(frame: NSRect(origin: .zero, size: outer.size), width: borderWidth, color: color)
        contentView = view
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    /// 画环形边框（外矩形减内矩形）的视图。
    private final class BorderView: NSView {
        private let width: CGFloat

        private let color: NSColor

        init(frame: NSRect, width: CGFloat, color: NSColor) {
            self.width = width
            self.color = color
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let outer = bounds
            let inner = outer.insetBy(dx: width, dy: width)
            let outerPath = CGPath(rect: outer, transform: nil)
            let innerPath = CGPath(rect: inner, transform: nil)
            // 外 ∖ 内 = 环形边框
            context.addPath(outerPath)
            context.addPath(innerPath)
            context.setFillColor(color.withAlphaComponent(0.9).cgColor)
            context.fillPath(using: .evenOdd)

            // 四角小把手（提示可辨认）
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            for corner in [inner.origin, CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
                let rect = CGRect(x: corner.x - width / 2, y: corner.y - width / 2, width: width * 2, height: width * 2)
                context.strokeEllipse(in: rect)
            }
        }
    }
}
