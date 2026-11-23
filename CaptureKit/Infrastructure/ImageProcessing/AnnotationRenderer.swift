import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// 标注统一渲染管线（DESIGN.md §7.5）。
/// 画布实时显示与最终导出合成复用同一实现，保证两者一致。
///
/// 坐标约定：图像坐标系（y 向上、原点左下），与画布视口转换一致。
/// 马赛克/模糊需要原始图像像素：调用方必须传入 baseImage（nil 时跳过效果类标注）。
enum AnnotationRenderer {
    /// CIContext 复用（模糊渲染）。
    private static let ciContext = CIContext()

    /// 绘制全部标注（按数组顺序，后绘制在上层）。
    static func draw(_ annotations: [Annotation], baseImage: CGImage?, in context: CGContext) {
        for annotation in annotations {
            draw(annotation, baseImage: baseImage, in: context)
        }
    }

    /// 绘制单个标注。
    static func draw(_ annotation: Annotation, baseImage: CGImage?, in context: CGContext) {
        switch annotation.geometry {
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, style: annotation.style, in: context)

        case .rect(let rect):
            drawRect(rect, style: annotation.style, in: context)

        case .ellipse(let rect):
            drawEllipse(rect, style: annotation.style, in: context)

        case .text(let origin, let string):
            drawText(string, at: origin, style: annotation.style, in: context)

        case .brush(let points):
            drawBrush(points, style: annotation.style, in: context)

        case .mosaic(let rect):
            if let baseImage {
                drawMosaic(rect, annotationID: annotation.id, baseImage: baseImage, granularity: annotation.style.mosaicGranularity, in: context)
            }

        case .blur(let rect):
            if let baseImage {
                drawBlur(rect, annotationID: annotation.id, baseImage: baseImage, radius: annotation.style.blurRadius, in: context)
            }

        case .numberedMarker(let center, let number):
            drawNumberedMarker(center: center, number: number, style: annotation.style, in: context)
        }
    }

    /// 合成导出：原始图片 + 全部标注 → 新 CGImage。
    /// 原始图片不被修改（非破坏性编辑，plan.md §2.4.3）。
    static func compose(baseImage: CGImage, annotations: [Annotation]) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // 坐标系与画布一致：CGImage 首行在顶部 → y 向上映射
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        draw(annotations, baseImage: baseImage, in: context)
        return context.makeImage()
    }

    // MARK: - 各类型绘制

    private static func drawArrow(from: CGPoint, to: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let color = style.color.nsColor.cgColor
        let width = max(1, style.lineWidth)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = width * 3.2 + 6
        let shaftEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.7,
            y: to.y - sin(angle) * headLength * 0.7
        )

        // 主干
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: from)
        context.addLine(to: shaftEnd)
        context.strokePath()

        // 箭头头部（实心三角）
        let wing = CGFloat.pi / 7
        let p1 = CGPoint(x: to.x - cos(angle - wing) * headLength, y: to.y - sin(angle - wing) * headLength)
        let p2 = CGPoint(x: to.x - cos(angle + wing) * headLength, y: to.y - sin(angle + wing) * headLength)
        context.setFillColor(color)
        context.beginPath()
        context.move(to: to)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
    }

    private static func drawRect(_ rect: CGRect, style: AnnotationStyle, in context: CGContext) {
        let color = style.color.nsColor.cgColor
        if style.isFilled {
            context.setFillColor(color.copy(alpha: 0.28) ?? color)
            context.fill(rect)
        }
        context.setStrokeColor(color)
        context.setLineWidth(max(1, style.lineWidth))
        context.stroke(rect)
    }

    private static func drawEllipse(_ rect: CGRect, style: AnnotationStyle, in context: CGContext) {
        let color = style.color.nsColor.cgColor
        if style.isFilled {
            context.setFillColor(color.copy(alpha: 0.28) ?? color)
            context.fillEllipse(in: rect)
        }
        context.setStrokeColor(color)
        context.setLineWidth(max(1, style.lineWidth))
        context.strokeEllipse(in: rect)
    }

    private static func drawText(_ string: String, at origin: CGPoint, style: AnnotationStyle, in context: CGContext) {
        guard !string.isEmpty else { return }
        // NSString.draw 需要 NSGraphicsContext（画布与位图上下文通用）
        let saved = NSGraphicsContext.current
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        (string as NSString).draw(at: origin, withAttributes: AnnotationTextMeasurer.attributes(style: style))
        NSGraphicsContext.current = saved
    }

    // MARK: - 马赛克 / 模糊 / 编号

    /// 效果渲染缓存（ADR-014 优化：画布缩放/拖动频繁重绘时避免重复计算）。
    /// key 含标注 ID + 区域 + 参数 + baseImage 身份（裁剪后自动失效）。
    enum EffectRenderCache {
        static let cache: NSCache<NSString, CGImage> = {
            let cache = NSCache<NSString, CGImage>()
            cache.countLimit = 32
            return cache
        }()

        static func key(kind: String, annotationID: UUID, rect: CGRect, parameter: CGFloat, base: CGImage) -> NSString {
            let identity = ObjectIdentifier(base).hashValue
            return "\(kind)|\(annotationID.uuidString)|\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)|\(parameter)|\(identity)" as NSString
        }
    }

    /// 马赛克：裁剪原图区域 → 缩小（块化）→ 最近邻放大 → 贴回（带缓存）。
    private static func drawMosaic(_ rect: CGRect, annotationID: UUID, baseImage: CGImage, granularity: CGFloat, in context: CGContext) {
        let effect = effectImage(
            kind: "mosaic", annotationID: annotationID, rect: rect, parameter: granularity, base: baseImage,
            compute: { region, clamped in
                mosaicImage(region: region, clamped: clamped, granularity: max(4, granularity))
            }
        )
        guard let effect else { return }
        blit(effect, in: rect, context: context)
    }

    /// 模糊：CIGaussianBlur 区域应用后贴回（带缓存）。
    private static func drawBlur(_ rect: CGRect, annotationID: UUID, baseImage: CGImage, radius: CGFloat, in context: CGContext) {
        let effect = effectImage(
            kind: "blur", annotationID: annotationID, rect: rect, parameter: radius, base: baseImage,
            compute: { region, _ in
                blurImage(region: region, radius: radius)
            }
        )
        guard let effect else { return }
        blit(effect, in: rect, context: context)
    }

    /// 缓存包装：命中直接返回；miss 计算、入缓存。
    private static func effectImage(
        kind: String,
        annotationID: UUID,
        rect: CGRect,
        parameter: CGFloat,
        base: CGImage,
        compute: (CGImage, CGRect) -> CGImage?
    ) -> CGImage? {
        let cacheKey = EffectRenderCache.key(kind: kind, annotationID: annotationID, rect: rect, parameter: parameter, base: base)
        if let cached = EffectRenderCache.cache.object(forKey: cacheKey) {
            return cached
        }
        let baseFrame = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let pixelRect = ScreenGeometry.pixelRect(logicalRect: rect, displayFrame: baseFrame, imagePixelSize: baseFrame.size)
        guard let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: baseFrame.size),
              let region = base.cropping(to: clamped),
              let result = compute(region, clamped)
        else { return nil }
        EffectRenderCache.cache.setObject(result, forKey: cacheKey)
        return result
    }

    /// 像素化：缩小 → 最近邻放大。
    private static func mosaicImage(region: CGImage, clamped: CGRect, granularity: CGFloat) -> CGImage? {
        let blocks = CGSize(
            width: max(1, clamped.width / granularity),
            height: max(1, clamped.height / granularity)
        )
        guard let smallContext = CGContext(
            data: nil,
            width: Int(blocks.width),
            height: Int(blocks.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        smallContext.interpolationQuality = .medium
        smallContext.draw(region, in: CGRect(origin: .zero, size: blocks))
        guard let small = smallContext.makeImage() else { return nil }

        // 最近邻放大回原尺寸
        guard let bigContext = CGContext(
            data: nil,
            width: Int(clamped.width),
            height: Int(clamped.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        bigContext.interpolationQuality = .none
        bigContext.draw(small, in: CGRect(origin: .zero, size: clamped.size))
        return bigContext.makeImage()
    }

    /// 区域模糊。
    private static func blurImage(region: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: region)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(max(1, radius * 2), forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage else { return nil }
        // blur 扩展 extent → 裁剪回原区域
        let cropped = output.cropped(to: input.extent)
        return ciContext.createCGImage(cropped, from: input.extent)
    }

    /// 像素图像（y 向下）贴回画布（y 向上）。
    private static func blit(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// 编号标注：实心圆 + 白色数字。
    private static func drawNumberedMarker(center: CGPoint, number: Int, style: AnnotationStyle, in context: CGContext) {
        let diameter = max(14, style.fontSize)
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.setFillColor(style.color.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect)

        let text = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
        NSGraphicsContext.current = saved
    }

    private static func drawBrush(_ points: [CGPoint], style: AnnotationStyle, in context: CGContext) {
        guard points.count == 1, let first = points.first else {
            guard points.count > 1 else { return }
            context.setStrokeColor(style.color.nsColor.cgColor)
            context.setLineWidth(max(1, style.lineWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: points[0])
            for index in 1..<points.count {
                context.addLine(to: points[index])
            }
            context.strokePath()
            return
        }
        // 单点 → 圆点
        context.setFillColor(style.color.nsColor.cgColor)
        let radius = max(1, style.lineWidth) / 2
        context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
    }
}
