import CoreGraphics
import Foundation

/// Overlay 选区内标注 → 像素图像标注的缩放转换（批次 2）。
///
/// Overlay 标注使用选区本地逻辑坐标（原点 = 选区左下角，y 向上，单位 pt）；
/// 导出合成需要像素图像坐标。几何经 `AnnotationGeometry.scaled(from:to:)`
/// 逐轴映射，样式参数（线宽/字号/马赛克粒度/模糊半径）按 y 轴比例等比缩放，
/// 保证导出与屏幕所见一致。
enum OverlayAnnotationExporter {
    /// 批量缩放（保持顺序）。
    static func scale(annotations: [Annotation], selectionSize: CGSize, imageSize: CGSize) -> [Annotation] {
        guard selectionSize.width > 0, selectionSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return [] }

        let source = CGRect(origin: .zero, size: selectionSize)
        let target = CGRect(origin: .zero, size: imageSize)
        return annotations.map { scale($0, source: source, target: target) }
    }

    /// 单条缩放。
    static func scale(_ annotation: Annotation, source: CGRect, target: CGRect) -> Annotation {
        let scaleY = target.height / source.height

        var scaled = annotation
        scaled.geometry = annotation.geometry.scaled(from: source, to: target)

        var style = annotation.style
        style.lineWidth = max(1, annotation.style.lineWidth * scaleY)
        style.fontSize = max(9, annotation.style.fontSize * scaleY)
        style.mosaicGranularity = max(4, annotation.style.mosaicGranularity * scaleY)
        style.blurRadius = max(1, annotation.style.blurRadius * scaleY)
        scaled.style = style
        return scaled
    }
}
