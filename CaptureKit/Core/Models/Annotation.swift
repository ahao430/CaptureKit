import AppKit
import CoreGraphics
import Foundation

// MARK: - 类型

/// 标注类型（plan.md §2.4.3）。
enum AnnotationType: String, Codable, CaseIterable {
    case arrow
    case rectangle
    case ellipse
    case text
    case brush
    case mosaic
    case blur
    case numberedMarker

    var displayName: String {
        switch self {
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .brush: return "画笔"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .numberedMarker: return "编号"
        }
    }
}

/// 标注颜色（Codable 中性模型；NSColor 映射在渲染层）。
enum AnnotationColor: String, Codable, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case white
    case black

    /// 画布/导出用 NSColor。
    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        case .orange: return NSColor(red: 1.0, green: 0.58, blue: 0.04, alpha: 1)
        case .yellow: return NSColor(red: 1.0, green: 0.80, blue: 0.02, alpha: 1)
        case .green: return NSColor(red: 0.19, green: 0.78, blue: 0.20, alpha: 1)
        case .blue: return NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        case .purple: return NSColor(red: 0.69, green: 0.33, blue: 0.96, alpha: 1)
        case .white: return NSColor.white
        case .black: return NSColor.black
        }
    }
}

/// 标注样式（ui-design.md §6.5 属性面板对应字段；按类型使用相关字段）。
struct AnnotationStyle: Equatable, Codable {
    var color: AnnotationColor
    var lineWidth: CGFloat
    /// 矩形/椭圆是否填充
    var isFilled: Bool
    /// 文字字号 / 编号圆直径
    var fontSize: CGFloat
    /// 马赛克粒度（像素块大小）
    var mosaicGranularity: CGFloat
    /// 模糊强度
    var blurRadius: CGFloat

    static let `default` = AnnotationStyle(
        color: .red, lineWidth: 4, isFilled: false, fontSize: 18,
        mosaicGranularity: 16, blurRadius: 15
    )

    enum CodingKeys: String, CodingKey {
        case color, lineWidth, isFilled, fontSize, mosaicGranularity, blurRadius
    }

    init(color: AnnotationColor, lineWidth: CGFloat, isFilled: Bool, fontSize: CGFloat,
         mosaicGranularity: CGFloat = 16, blurRadius: CGFloat = 15) {
        self.color = color
        self.lineWidth = lineWidth
        self.isFilled = isFilled
        self.fontSize = fontSize
        self.mosaicGranularity = mosaicGranularity
        self.blurRadius = blurRadius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(AnnotationColor.self, forKey: .color) ?? .red
        lineWidth = try container.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 4
        isFilled = try container.decodeIfPresent(Bool.self, forKey: .isFilled) ?? false
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 18
        mosaicGranularity = try container.decodeIfPresent(CGFloat.self, forKey: .mosaicGranularity) ?? 16
        blurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .blurRadius) ?? 15
    }

    static func == (lhs: AnnotationStyle, rhs: AnnotationStyle) -> Bool {
        lhs.color == rhs.color
            && lhs.lineWidth == rhs.lineWidth
            && lhs.isFilled == rhs.isFilled
            && lhs.fontSize == rhs.fontSize
            && lhs.mosaicGranularity == rhs.mosaicGranularity
            && lhs.blurRadius == rhs.blurRadius
    }
}

// MARK: - 几何

/// 标注几何（值类型；图像坐标系，y 向上、原点在图像左下，与画布一致）。
enum AnnotationGeometry: Equatable, Codable {
    case arrow(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case ellipse(inRect: CGRect)
    case text(origin: CGPoint, string: String)
    case brush(points: [CGPoint])
    case mosaic(CGRect)
    case blur(CGRect)
    case numberedMarker(center: CGPoint, number: Int)

    /// 包围盒（含线宽/字号影响）。text 需要样式估算尺寸。
    func boundingBox(style: AnnotationStyle) -> CGRect {
        switch self {
        case .arrow(let from, let to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(from.x - to.x), height: abs(from.y - to.y))
        case .rect(let rect):
            return rect
        case .ellipse(inRect: let rect):
            return rect
        case .text(let origin, let string):
            let size = AnnotationTextMeasurer.size(of: string, style: style)
            return CGRect(origin: origin, size: size)
        case .mosaic(let rect):
            return rect
        case .blur(let rect):
            return rect
        case .numberedMarker(let center, _):
            let diameter = style.fontSize
            return CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        case .brush(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// 平移。
    func translated(dx: CGFloat, dy: CGFloat) -> AnnotationGeometry {
        switch self {
        case .arrow(let from, let to):
            return .arrow(from: from.offsetBy(dx, dy), to: to.offsetBy(dx, dy))
        case .rect(let rect):
            return .rect(rect.offsetBy(dx: dx, dy: dy))
        case .ellipse(let rect):
            return .ellipse(inRect: rect.offsetBy(dx: dx, dy: dy))
        case .text(let origin, let string):
            return .text(origin: origin.offsetBy(dx, dy), string: string)
        case .brush(let points):
            return .brush(points: points.map { $0.offsetBy(dx, dy) })
        case .mosaic(let rect):
            return .mosaic(rect.offsetBy(dx: dx, dy: dy))
        case .blur(let rect):
            return .blur(rect.offsetBy(dx: dx, dy: dy))
        case .numberedMarker(let center, let number):
            return .numberedMarker(center: center.offsetBy(dx, dy), number: number)
        }
    }

    /// 从旧包围盒映射到新包围盒（resize 用，允许等比/非等比缩放）。
    func scaled(from source: CGRect, to target: CGRect) -> AnnotationGeometry {
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: source.width == 0 ? target.minX : (p.x - source.minX) / source.width * target.width + target.minX,
                y: source.height == 0 ? target.minY : (p.y - source.minY) / source.height * target.height + target.minY
            )
        }
        func mapRect(_ rect: CGRect) -> CGRect {
            let a = map(rect.origin)
            let b = map(CGPoint(x: rect.maxX, y: rect.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
        switch self {
        case .arrow(let from, let to):
            return .arrow(from: map(from), to: map(to))
        case .rect(let rect):
            return .rect(mapRect(rect))
        case .ellipse(let rect):
            return .ellipse(inRect: mapRect(rect))
        case .text(let origin, let string):
            return .text(origin: map(origin), string: string)
        case .brush(let points):
            return .brush(points: points.map(map))
        case .mosaic(let rect):
            return .mosaic(mapRect(rect))
        case .blur(let rect):
            return .blur(mapRect(rect))
        case .numberedMarker(let center, let number):
            return .numberedMarker(center: map(center), number: number)
        }
    }

    /// 命中测试。
    /// - Parameters:
    ///   - point: 图像坐标点。
    ///   - tolerance: 命中容差（pt）。
    func hitTest(contains point: CGPoint, tolerance: CGFloat, style: AnnotationStyle) -> Bool {
        switch self {
        case .arrow(let from, let to):
            return Self.distance(from: point, toSegment: (from, to)) <= style.lineWidth / 2 + tolerance
        case .rect(let rect):
            if style.isFilled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return Self.isNearEdge(of: rect, at: point, distance: style.lineWidth / 2 + tolerance)
        case .ellipse(let rect):
            if style.isFilled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return Self.isNearEllipseEdge(of: rect, at: point, tolerance: style.lineWidth / 2 + tolerance)
        case .text:
            return boundingBox(style: style).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .mosaic(let rect), .blur(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .numberedMarker(let center, _):
            return hypot(point.x - center.x, point.y - center.y) <= style.fontSize / 2 + tolerance
        case .brush(let points):
            guard points.count == 1 else {
                for index in 1..<max(points.count, 1) where index < points.count {
                    if Self.distance(from: point, toSegment: (points[index - 1], points[index])) <= style.lineWidth / 2 + tolerance {
                        return true
                    }
                }
                return false
            }
            if let only = points.first {
                return Self.distance(from: point, toSegment: (only, only)) <= style.lineWidth / 2 + tolerance
            }
            return false
        }
    }

    // MARK: 距离工具

    /// 点到线段距离。
    static func distance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        if lengthSquared == 0 {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared))
        let projected = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    /// 点是否贴近矩形边框。
    static func isNearEdge(of rect: CGRect, at point: CGPoint, distance threshold: CGFloat) -> Bool {
        let outer = rect.insetBy(dx: -threshold, dy: -threshold)
        let inner = rect.insetBy(dx: threshold, dy: threshold)
        return outer.contains(point) && !inner.contains(point)
    }

    /// 点是否贴近椭圆边（简化：归一化半径距离 1±ε）。
    static func isNearEllipseEdge(of rect: CGRect, at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let dx = (point.x - rect.midX) / (rect.width / 2)
        let dy = (point.y - rect.midY) / (rect.height / 2)
        let r = hypot(dx, dy)
        // 归一化半径 1 对应椭圆边；容差换算为近似半径区间
        let toleranceRatio = tolerance / min(rect.width, rect.height) * 2 + 0.05
        return r >= 1 - toleranceRatio && r <= 1 + toleranceRatio
    }
}

private extension CGPoint {
    func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

// MARK: - 文本测量（AppKit 仅用于字体度量）

/// 文本尺寸估算：导出与画布显示共用，保证一致（DESIGN.md §7.5）。
enum AnnotationTextMeasurer {
    static func attributes(style: AnnotationStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
            .foregroundColor: style.color.nsColor,
        ]
    }

    static func size(of string: String, style: AnnotationStyle) -> CGSize {
        guard !string.isEmpty else { return CGSize(width: style.fontSize, height: style.fontSize) }
        return (string as NSString).size(withAttributes: attributes(style: style))
    }
}

// MARK: - 标注

/// 标注对象（值类型模型 + Renderer 绘制，DESIGN.md §7.3）。
struct Annotation: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var type: AnnotationType
    var geometry: AnnotationGeometry
    var style: AnnotationStyle

    init(type: AnnotationType, geometry: AnnotationGeometry, style: AnnotationStyle = .default) {
        self.type = type
        self.geometry = geometry
        self.style = style
    }

    init(id: UUID, type: AnnotationType, geometry: AnnotationGeometry, style: AnnotationStyle = .default) {
        self.id = id
        self.type = type
        self.geometry = geometry
        self.style = style
    }

    func boundingBox() -> CGRect {
        geometry.boundingBox(style: style)
    }

    func hitTest(contains point: CGPoint, tolerance: CGFloat) -> Bool {
        geometry.hitTest(contains: point, tolerance: tolerance, style: style)
    }
}
