import CoreGraphics
import Foundation

/// 鼠标驱动滚动（长截图会话内）：鼠标靠近选区下边缘 → 向下滚，靠近上边缘 → 向上滚，
/// 越靠边越快；选区中部与选区外不滚动。纯函数，可单测。
enum ScrollEdgeDriver {
    struct Plan: Equatable {
        /// 滚动像素（正 = 向下，负 = 向上）；0 表示不滚
        let pixels: CGFloat
        /// 注入点（AppKit 全局坐标）
        let location: CGPoint
    }

    /// - Parameters:
    ///   - mouse: 鼠标全局点（AppKit 坐标）。
    ///   - region: 选区（AppKit 全局坐标）。
    ///   - bandFraction: 上下边缘触发带占选区高度的比例（0.1...0.5）。
    ///   - maxPixels: 紧贴边缘时的单次最大滚动像素。
    static func plan(
        mouse: CGPoint,
        region: CGRect,
        bandFraction: CGFloat = 0.28,
        maxPixels: CGFloat = 60
    ) -> Plan {
        guard region.width > 0, region.height > 0, region.contains(mouse) else {
            return Plan(pixels: 0, location: mouse)
        }
        let band = max(4, region.height * min(max(bandFraction, 0.1), 0.5))
        let fromBottom = mouse.y - region.minY
        let fromTop = region.maxY - mouse.y

        if fromBottom <= band {
            // 距下边 0 → maxPixels；距下边 band → 0
            let ratio = 1 - fromBottom / band
            return Plan(pixels: max(0, maxPixels * ratio), location: mouse)
        }
        if fromTop <= band {
            let ratio = 1 - fromTop / band
            return Plan(pixels: -max(0, maxPixels * ratio), location: mouse)
        }
        return Plan(pixels: 0, location: mouse)
    }
}
