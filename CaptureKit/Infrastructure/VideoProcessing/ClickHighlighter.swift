import AppKit
import CoreGraphics
import CoreVideo
import Foundation

/// 全局点击监听（Phase 6：录制鼠标点击效果）。
/// NSEvent 全局监听鼠标事件不需要辅助功能权限（键盘事件才需要）。
/// 事件在主线程回调；绘制由帧管线按「帧到达时刻」驱动（不依赖 PTS 对齐）。
@MainActor
final class ClickHighlighter {
    struct ClickEvent {
        let globalPoint: CGPoint
        let wallClock: Date
    }

    /// 效果存活时长（秒）。
    static let effectDuration: TimeInterval = 0.45

    private(set) var events: [ClickEvent] = []
    private var monitor: Any?
    private(set) var isRunning = false

    func start() {
        guard monitor == nil else { return }
        events.removeAll()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 全局坐标（屏幕左下原点，与 AppKit 一致）
                self.events.append(ClickEvent(globalPoint: NSEvent.mouseLocation, wallClock: Date()))
                // 上限裁剪
                if self.events.count > 16 {
                    self.events.removeFirst(self.events.count - 16)
                }
            }
        }
        isRunning = true
        Log.recording.debug("Click highlighter started")
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        events.removeAll()
        isRunning = false
    }

    /// 当前活跃效果（progress 0→1）。由帧到达时调用。
    /// - Parameter now: 帧处理时刻（wall clock）。
    func activeEffects(now: Date = Date()) -> [(globalPoint: CGPoint, progress: Double)] {
        let cutoff = now.addingTimeInterval(-Self.effectDuration)
        events.removeAll { $0.wallClock < cutoff }
        return events.map { event in
            let elapsed = now.timeIntervalSince(event.wallClock)
            return (event.globalPoint, min(1, max(0, elapsed / Self.effectDuration)))
        }
    }
}

/// 点击效果坐标换算与帧内绘制（纯函数，可单测）。
enum ClickEffectRenderer {
    /// 全局点 → 输出帧像素坐标（原点左上）。
    /// - Parameters:
    ///   - global: 全局 AppKit 坐标（y 向上）。
    ///   - contentOrigin: 捕获内容在全局坐标的原点（区域 = 选区原点；全屏 = 显示器 frame 原点）。
    ///   - contentLogicalSize: 捕获内容逻辑尺寸。
    ///   - outputPixelSize: 输出帧像素尺寸。
    static func pixelPoint(global: CGPoint,
                            contentOrigin: CGPoint,
                            contentLogicalSize: CGSize,
                            outputPixelSize: CGSize) -> CGPoint? {
        let localX = global.x - contentOrigin.x
        let localY = global.y - contentOrigin.y
        guard localX >= -20, localY >= -20,
              localX <= contentLogicalSize.width + 20, localY <= contentLogicalSize.height + 20
        else { return nil }
        let scaleX = outputPixelSize.width / max(1, contentLogicalSize.width)
        let scaleY = outputPixelSize.height / max(1, contentLogicalSize.height)
        // y 翻转（AppKit 左下 → 像素左上）
        return CGPoint(
            x: localX * scaleX,
            y: outputPixelSize.height - localY * scaleY
        )
    }

    /// 在像素缓冲上绘制扩散圆环效果（就地修改）。
    static func drawEffects(on buffer: CVPixelBuffer,
                            effects: [(point: CGPoint, progress: Double)],
                            color: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.04, 0.52, 1.0)) {
        guard !effects.isEmpty else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        for effect in effects {
            let progress = effect.progress
            let alpha = (1 - progress) * 0.65
            // 扩散外环
            let outerRadius = 14 + progress * 34
            context.setStrokeColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha))
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(
                x: effect.point.x - outerRadius,
                y: effect.point.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            ))
            // 实心内点
            let innerAlpha = (1 - progress) * 0.85
            context.setFillColor(CGColor(red: color.red, green: color.green, blue: color.blue, alpha: innerAlpha))
            let innerRadius: CGFloat = 7 * (1 - progress * 0.4)
            context.fillEllipse(in: CGRect(
                x: effect.point.x - innerRadius,
                y: effect.point.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            ))
        }
        context.flush()
    }
}
