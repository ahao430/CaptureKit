import CoreGraphics
import Foundation

/// 贴图窗口的纯计算（缩放 / 透明度步进），可单测。
enum PinnedImageMath {
    /// 滚轮缩放：以中心为锚，按 delta 步进（正 = 放大）。
    /// - Parameters:
    ///   - current: 当前内容尺寸。
    ///   - delta: 滚轮增量（正 = 放大，负 = 缩小）。
    ///   - minSide: 最短边下限（pt）。
    ///   - maxSide: 最长边上限（pt）。
    static func zoomedSize(current: CGSize, delta: CGFloat, minSide: CGFloat = 80, maxSide: CGFloat) -> CGSize {
        guard current.width > 0, current.height > 0 else { return current }
        var scale = pow(1.1, delta)
        // 等比钳制：最短边不小于 minSide，最长边不超过 maxSide
        let minScale = minSide / min(current.width, current.height)
        let maxScale = maxSide / max(current.width, current.height)
        scale = min(max(scale, minScale), max(maxScale, minScale))
        return CGSize(width: current.width * scale, height: current.height * scale)
    }

    /// 透明度步进：0.05/格，范围 [lowerBound, 1]。
    static func steppedOpacity(current: CGFloat, delta: CGFloat, lowerBound: CGFloat = 0.15) -> CGFloat {
        min(1, max(lowerBound, current + delta * 0.05))
    }
}
