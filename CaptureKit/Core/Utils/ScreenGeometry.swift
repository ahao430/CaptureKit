import CoreGraphics
import Foundation

/// 选区 8 个调整控制点（AppKit 坐标，y 向上）。
enum SelectionHandle: Int, CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    /// 控制点在选区上的全局坐标。
    func position(on rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

/// 统一坐标转换（design.md §5）。
///
/// 坐标体系约定：
/// - Overlay 交互、SCDisplay/NSScreen frame：AppKit 全局逻辑坐标（原点在主屏左下，允许负坐标）。
/// - ScreenCaptureKit 输出的 CGImage：物理像素坐标（原点在图像左上）。
/// - 所有逻辑坐标 → 像素坐标的转换必须经过本类型，业务代码不得自行乘 backingScaleFactor。
enum ScreenGeometry {
    /// 将全局 AppKit 逻辑坐标矩形转换为某显示器捕获图像内的像素矩形。
    ///
    /// - Parameters:
    ///   - logicalRect: 全局 AppKit 逻辑坐标矩形（原点左下）。
    ///   - displayFrame: 目标显示器的全局逻辑 frame（`SCDisplay.frame` / `NSScreen.frame`）。
    ///   - imagePixelSize: 实际捕获图像的像素尺寸。
    ///
    /// 缩放比例由实际图像尺寸与显示器逻辑尺寸计算得出，
    /// 不假设 `backingScaleFactor`，以兼容输出尺寸与请求不一致的情况。
    static func pixelRect(logicalRect: CGRect, displayFrame: CGRect, imagePixelSize: CGSize) -> CGRect {
        precondition(displayFrame.width > 0 && displayFrame.height > 0, "displayFrame 不能为空")
        precondition(imagePixelSize.width > 0 && imagePixelSize.height > 0, "imagePixelSize 不能为空")

        let scaleX = imagePixelSize.width / displayFrame.width
        let scaleY = imagePixelSize.height / displayFrame.height

        // 转换到显示器本地逻辑坐标
        let localX = logicalRect.minX - displayFrame.minX
        let localY = logicalRect.minY - displayFrame.minY

        // AppKit 原点在左下，图像原点在左上 → y 轴翻转
        let pixelX = localX * scaleX
        let pixelY = (displayFrame.height - (localY + logicalRect.height)) * scaleY

        return CGRect(x: pixelX, y: pixelY, width: logicalRect.width * scaleX, height: logicalRect.height * scaleY)
    }

    /// 将像素矩形裁剪到图像边界内并对齐整数像素，防止 CGImage.cropping 越界失败。
    static func clampedPixelRect(_ rect: CGRect, in imageSize: CGSize) -> CGRect? {
        let integral = rect.integral
        let bounds = CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        let clipped = integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        // 对齐整数像素
        let x = floor(clipped.minX), y = floor(clipped.minY)
        let w = ceil(clipped.maxX) - x, h = ceil(clipped.maxY) - y
        guard w >= 1, h >= 1 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 在候选显示器中选择与指定全局矩形相交面积最大的一台。
    /// - Returns: 相交面积为零时返回 nil。
    static func bestDisplay(for rect: CGRect, candidates: [(displayID: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for candidate in candidates {
            let intersection = rect.intersection(candidate.frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > 0, best == nil || area > best!.area {
                best = (candidate.displayID, area)
            }
        }
        return best?.id
    }

    /// 找到包含指定全局点的窗口（取 frame 面积最小者，即最上层最贴合的窗口）。
    /// 用于 Overlay 双击捕获窗口。
    static func window(at point: CGPoint, candidates: [(windowID: CGWindowID, frame: CGRect)]) -> CGWindowID? {
        var best: (id: CGWindowID, area: CGFloat)?
        for candidate in candidates {
            // frame 为空（宽度或高度为 0/1）的窗口通常是系统元素，跳过
            guard candidate.frame.width > 1, candidate.frame.height > 1 else { continue }
            guard candidate.frame.contains(point) else { continue }
            let area = candidate.frame.width * candidate.frame.height
            if best == nil || area < best!.area {
                best = (candidate.windowID, area)
            }
        }
        return best?.id
    }

    // MARK: - 选区调整（Phase 1）

    /// 命中选区的控制点。
    /// - Parameters:
    ///   - point: 全局逻辑坐标点。
    ///   - tolerance: 命中半径（pt）。
    static func handle(at point: CGPoint, of selection: CGRect, tolerance: CGFloat = 8) -> SelectionHandle? {
        // 角点优先于边中点
        let ordered: [SelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for handle in ordered {
            let position = handle.position(on: selection)
            if hypot(point.x - position.x, point.y - position.y) <= tolerance {
                return handle
            }
        }
        return nil
    }

    /// 拖拽控制点调整选区：按 handle 移动对应边/角，对侧边固定。
    /// 允许拖过对边产生翻转（返回归一化矩形）。
    static func resizeRect(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    /// 方向键微调选区位置。
    static func movedRect(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x + dx, y: rect.origin.y + dy, width: rect.width, height: rect.height)
    }

    /// 将点吸附到附近矩形边缘（窗口吸附，threshold 内替换坐标）。
    static func snappedPoint(_ point: CGPoint, toEdgesIn frames: [CGRect], threshold: CGFloat) -> CGPoint {
        guard threshold > 0, !frames.isEmpty else { return point }
        var snapped = point
        for frame in frames {
            if abs(snapped.x - frame.minX) < threshold {
                snapped.x = frame.minX
            } else if abs(snapped.x - frame.maxX) < threshold {
                snapped.x = frame.maxX
            }
            if abs(snapped.y - frame.minY) < threshold {
                snapped.y = frame.minY
            } else if abs(snapped.y - frame.maxY) < threshold {
                snapped.y = frame.maxY
            }
        }
        return snapped
    }

    /// 按固定宽高比（w/h）约束从锚点拖出的矩形（裁剪比例约束）。
    /// - Parameters:
    ///   - anchor: 拖拽起点（保持为矩形一角）。
    ///   - point: 当前拖拽点。
    ///   - aspect: 宽/高比；nil 或非正值返回自由矩形。
    static func aspectConstrainedRect(from anchor: CGPoint, to point: CGPoint, aspect: CGFloat?) -> CGRect {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard let aspect, aspect > 0 else {
            return CGRect(
                x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(dx), height: abs(dy)
            )
        }
        // 两个候选（保持拖拽方向符号），取面积较大者
        let candidateA = (width: dx, height: dx / aspect)
        let candidateB = (width: dy * aspect, height: dy)
        let chosen = abs(candidateA.width) * abs(candidateA.height) >= abs(candidateB.width) * abs(candidateB.height)
            ? candidateA : candidateB
        return CGRect(
            x: min(anchor.x, anchor.x + chosen.width),
            y: min(anchor.y, anchor.y + chosen.height),
            width: abs(chosen.width),
            height: abs(chosen.height)
        )
    }
}
