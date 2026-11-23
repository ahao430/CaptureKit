import CoreGraphics
import XCTest

@testable import CaptureKit

/// Phase 2 扩展工具：马赛克/模糊/编号几何 + 裁剪命令 + 比例约束。
final class AnnotationExtensionTests: XCTestCase {
    private let style = AnnotationStyle.default

    // MARK: - 新几何类型

    func testMosaicGeometryBasics() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 60)
        let geometry = AnnotationGeometry.mosaic(rect)

        XCTAssertEqual(geometry.boundingBox(style: style), rect)
        XCTAssertEqual(geometry.translated(dx: 5, dy: 5), .mosaic(rect.offsetBy(dx: 5, dy: 5)))
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 50, y: 50), tolerance: 4, style: style))
        XCTAssertFalse(geometry.hitTest(contains: CGPoint(x: 200, y: 200), tolerance: 4, style: style))
    }

    func testNumberedMarkerGeometry() {
        let center = CGPoint(x: 50, y: 50)
        let geometry = AnnotationGeometry.numberedMarker(center: center, number: 3)

        let box = geometry.boundingBox(style: style)
        XCTAssertEqual(box.midX, center.x)
        XCTAssertEqual(box.midY, center.y)
        XCTAssertEqual(box.width, style.fontSize)

        // 命中：圆内命中、圆外不命中
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 55, y: 55), tolerance: 2, style: style))
        XCTAssertFalse(geometry.hitTest(contains: CGPoint(x: 90, y: 90), tolerance: 2, style: style))

        // 平移保持编号
        let moved = geometry.translated(dx: 10, dy: 0)
        XCTAssertEqual(moved, .numberedMarker(center: CGPoint(x: 60, y: 50), number: 3))
    }

    func testStyleDecodingMissingNewFields() throws {
        // 旧版本样式（无 mosaicGranularity/blurRadius）→ 默认值
        let legacy = #"{"color":"blue","lineWidth":6,"isFilled":true,"fontSize":20}"#
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.color, .blue)
        XCTAssertEqual(decoded.lineWidth, 6)
        XCTAssertEqual(decoded.mosaicGranularity, 16)
        XCTAssertEqual(decoded.blurRadius, 15)
    }

    // MARK: - 比例约束

    func testAspectConstrainedFree() {
        let rect = ScreenGeometry.aspectConstrainedRect(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 50),
            aspect: nil
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testAspectConstrainedSquare() {
        // 拖到 (100, 50)，x 主导 → 1:1 → (100×100)
        let rect = ScreenGeometry.aspectConstrainedRect(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 50),
            aspect: 1
        )
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 100, accuracy: 0.001)
    }

    func testAspectConstrained16x9BackwardDrag() {
        // 反向拖拽保持方向（负宽高归一后为正矩形）
        let rect = ScreenGeometry.aspectConstrainedRect(
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 20, y: 110), // dx=-180, dy=-90
            aspect: 16.0 / 9.0
        )
        // dx 主导：width=-180, height=-180/(16/9)=-101.25
        XCTAssertEqual(rect.width, 180, accuracy: 0.001)
        XCTAssertEqual(rect.height, 101.25, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 200, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
    }

    // MARK: - 裁剪命令与文档

    @MainActor
    func testApplyCropTranslatesAnnotationsAndDropsOutside() {
        let image = CGImage.testImage(width: 400, height: 300)
        let document = EditorDocument(baseImage: image)

        // 一个在裁剪区内、一个在裁剪区外
        let inside = Annotation(type: .arrow, geometry: .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 80)))
        let outside = Annotation(type: .arrow, geometry: .arrow(from: CGPoint(x: 350, y: 250), to: CGPoint(x: 390, y: 280)))
        document.add(inside)
        document.add(outside)
        XCTAssertEqual(document.annotations.count, 2)

        document.applyCrop(CGRect(x: 20, y: 20, width: 200, height: 150))

        // 外部标注被剔除；内部标注平移 -20,-20
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(
            document.annotations.first?.geometry,
            .arrow(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 130, y: 60))
        )
        // 有效图像尺寸 = 裁剪区
        XCTAssertEqual(document.effectiveImage.width, 200)
        XCTAssertEqual(document.effectiveImage.height, 150)

        // 撤销 → 恢复原始
        document.undo()
        XCTAssertEqual(document.annotations.count, 2)
        XCTAssertEqual(document.effectiveImage.width, 400)
        XCTAssertNil(document.cropRect)
    }

    @MainActor
    func testResetCropRestoresCoordinates() {
        let image = CGImage.testImage(width: 200, height: 200)
        let document = EditorDocument(baseImage: image)
        let arrow = Annotation(type: .arrow, geometry: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 180)))
        document.add(arrow)

        document.applyCrop(CGRect(x: 50, y: 50, width: 100, height: 100))
        XCTAssertEqual(
            document.annotations.first?.geometry,
            .arrow(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 130, y: 130))
        )

        document.resetCrop()
        XCTAssertEqual(
            document.annotations.first?.geometry,
            .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 180))
        )
        XCTAssertEqual(document.effectiveImage.width, 200)
        XCTAssertNil(document.cropRect)
    }

    @MainActor
    func testNextMarkerNumberIncrements() {
        let image = CGImage.testImage(width: 50, height: 50)
        let document = EditorDocument(baseImage: image)
        XCTAssertEqual(document.nextMarkerNumber(), 1)

        document.add(Annotation(type: .numberedMarker, geometry: .numberedMarker(center: .zero, number: 1)))
        document.add(Annotation(type: .numberedMarker, geometry: .numberedMarker(center: .zero, number: 5)))
        XCTAssertEqual(document.nextMarkerNumber(), 6)
    }

    @MainActor
    func testHasUnexportedChangesLifecycle() {
        let image = CGImage.testImage(width: 50, height: 50)
        let document = EditorDocument(baseImage: image)
        XCTAssertFalse(document.hasUnexportedChanges)

        document.add(Annotation(type: .arrow, geometry: .arrow(from: .zero, to: CGPoint(x: 10, y: 0))))
        XCTAssertTrue(document.hasUnexportedChanges)

        document.markExported()
        XCTAssertFalse(document.hasUnexportedChanges)

        document.undo()
        XCTAssertTrue(document.hasUnexportedChanges)
    }

    // MARK: - 渲染（含效果类标注）

    func testComposeWithEffectAnnotations() {
        let base = CGImage.testImage(width: 120, height: 90)
        let annotations = [
            Annotation(type: .mosaic, geometry: .mosaic(CGRect(x: 10, y: 10, width: 40, height: 30))),
            Annotation(type: .blur, geometry: .blur(CGRect(x: 60, y: 40, width: 40, height: 30))),
            Annotation(type: .numberedMarker, geometry: .numberedMarker(center: CGPoint(x: 60, y: 45), number: 1)),
        ]
        let composed = AnnotationRenderer.compose(baseImage: base, annotations: annotations)
        XCTAssertNotNil(composed)
        XCTAssertEqual(composed?.width, 120)
        XCTAssertEqual(composed?.height, 90)
    }
}
