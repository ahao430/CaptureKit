import CoreGraphics
import XCTest

@testable import CaptureKit

/// 标注几何 + 命中测试（design.md §17.1 优先测试项）。
final class AnnotationGeometryTests: XCTestCase {
    private let style = AnnotationStyle(color: .red, lineWidth: 4, isFilled: false, fontSize: 18)

    // MARK: - 包围盒

    func testArrowBoundingBox() {
        let geometry = AnnotationGeometry.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70))
        XCTAssertEqual(geometry.boundingBox(style: style), CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testBrushBoundingBox() {
        let geometry = AnnotationGeometry.brush(points: [
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: -30), CGPoint(x: 20, y: 60),
        ])
        XCTAssertEqual(geometry.boundingBox(style: style), CGRect(x: 0, y: -30, width: 50, height: 90))
    }

    func testTextBoundingBoxUsesStyle() {
        let geometry = AnnotationGeometry.text(origin: CGPoint(x: 5, y: 5), string: "Hello")
        let box = geometry.boundingBox(style: style)
        XCTAssertEqual(box.origin, CGPoint(x: 5, y: 5))
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
    }

    // MARK: - 平移

    func testTranslated() {
        let rect = AnnotationGeometry.rect(CGRect(x: 10, y: 10, width: 30, height: 20))
        let moved = rect.translated(dx: 5, dy: -3)
        XCTAssertEqual(moved, .rect(CGRect(x: 15, y: 7, width: 30, height: 20)))

        let arrow = AnnotationGeometry.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10))
        XCTAssertEqual(
            arrow.translated(dx: 1, dy: 1),
            .arrow(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 11, y: 11))
        )
    }

    // MARK: - 缩放（resize）

    func testScaledRect() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 10, y: 10, width: 20, height: 40))
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 0, y: 0, width: 50, height: 200) // x 减半 y 翻倍
        let scaled = geometry.scaled(from: source, to: target)
        XCTAssertEqual(scaled, .rect(CGRect(x: 5, y: 20, width: 10, height: 80)))
    }

    func testScaledBrushPoints() {
        let geometry = AnnotationGeometry.brush(points: [CGPoint(x: 25, y: 75)])
        let scaled = geometry.scaled(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     to: CGRect(x: 100, y: 200, width: 200, height: 100))
        // x: 25/100*200+100=150, y: 75/100*100+200=275
        XCTAssertEqual(scaled, .brush(points: [CGPoint(x: 150, y: 275)]))
    }

    // MARK: - 命中

    func testArrowHitTest() {
        let geometry = AnnotationGeometry.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        // 线上
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 50, y: 2), tolerance: 4, style: style))
        // 线宽/2 + 容差 = 6，距离 5 命中
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 50, y: 5), tolerance: 4, style: style))
        // 太远
        XCTAssertFalse(geometry.hitTest(contains: CGPoint(x: 50, y: 20), tolerance: 4, style: style))
    }

    func testRectHitTestUnfilledOnlyNearEdge() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        // 边框附近命中
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 50, y: 98), tolerance: 4, style: style))
        // 中心（未填充）不命中
        XCTAssertFalse(geometry.hitTest(contains: CGPoint(x: 50, y: 50), tolerance: 4, style: style))
    }

    func testRectHitTestFilledInside() {
        var filled = style
        filled.isFilled = true
        let geometry = AnnotationGeometry.rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 50, y: 50), tolerance: 4, style: filled))
    }

    func testBrushHitTest() {
        let geometry = AnnotationGeometry.brush(points: [
            CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 80, y: 0),
        ])
        XCTAssertTrue(geometry.hitTest(contains: CGPoint(x: 60, y: 3), tolerance: 4, style: style))
        XCTAssertFalse(geometry.hitTest(contains: CGPoint(x: 60, y: 30), tolerance: 4, style: style))
    }

    // MARK: - 距离工具

    func testPointToSegmentDistance() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 100, y: 0)
        XCTAssertEqual(AnnotationGeometry.distance(from: CGPoint(x: 50, y: 30), toSegment: (a, b)), 30, accuracy: 0.001)
        // 投影超出线段端点 → 到端点距离
        XCTAssertEqual(AnnotationGeometry.distance(from: CGPoint(x: -30, y: 40), toSegment: (a, b)), 50, accuracy: 0.001)
        // 零长线段
        XCTAssertEqual(AnnotationGeometry.distance(from: CGPoint(x: 3, y: 4), toSegment: (a, a)), 5, accuracy: 0.001)
    }

    // MARK: - Codable

    func testAnnotationCodableRoundTrip() throws {
        let annotation = Annotation(type: .text, geometry: .text(origin: CGPoint(x: 1, y: 2), string: "你好"), style: .default)
        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        XCTAssertEqual(decoded, annotation)
    }
}

/// Command Pattern 撤销/重做（design.md §7.4）。
@MainActor
final class EditorCommandTests: XCTestCase {
    private func makeArrow(id: UUID = UUID(), from: CGPoint = .zero, to: CGPoint = CGPoint(x: 100, y: 0)) -> Annotation {
        Annotation(id: id, type: .arrow, geometry: .arrow(from: from, to: to), style: .default)
    }

    func testApplyAddAndRevert() {
        let annotation = makeArrow()
        var annotations: [Annotation] = []

        EditorCommand.apply(.add(annotation), to: &annotations)
        XCTAssertEqual(annotations.count, 1)

        EditorCommand.revert(.add(annotation), to: &annotations)
        XCTAssertTrue(annotations.isEmpty)
    }

    func testApplyRemoveAndRevert() {
        let annotation = makeArrow()
        var annotations = [annotation]

        EditorCommand.revert(.remove(annotation), to: &annotations) // revert remove = 恢复
        // remove 的 revert 是 append；先正确流：apply remove → 空；revert → 恢复
        var state = [annotation]
        EditorCommand.apply(.remove(annotation), to: &state)
        XCTAssertTrue(state.isEmpty)
        EditorCommand.revert(.remove(annotation), to: &state)
        XCTAssertEqual(state, [annotation])
        _ = annotations
    }

    func testApplyUpdateAndRevert() {
        let id = UUID()
        let original = makeArrow(id: id)
        var moved = original
        moved.geometry = .arrow(from: .zero, to: CGPoint(x: 200, y: 100))
        var annotations = [original]

        EditorCommand.apply(.update(from: original, to: moved), to: &annotations)
        XCTAssertEqual(annotations.first?.geometry, moved.geometry)

        EditorCommand.revert(.update(from: original, to: moved), to: &annotations)
        XCTAssertEqual(annotations.first?.geometry, original.geometry)
    }

    func testDocumentUndoRedoFlow() {
        let image = CGImage.testImage(width: 10, height: 10)
        let document = EditorDocument(baseImage: image)

        let annotation = makeArrow()
        document.add(annotation)
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)

        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.annotations.count, 1)

        // 移动 + 撤销
        document.move(id: annotation.id, dx: 30, dy: 30)
        let moved = document.annotations.first
        XCTAssertEqual(moved?.geometry, AnnotationGeometry.arrow(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 130, y: 30)))
        document.undo()
        XCTAssertEqual(document.annotations.first?.geometry, annotation.geometry)

        // 删除 + 撤销恢复选中
        document.remove(id: annotation.id)
        XCTAssertTrue(document.annotations.isEmpty)
        document.undo()
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.selectedAnnotationID, annotation.id)
    }

    func testDocumentUpdateStyleCommand() {
        let image = CGImage.testImage(width: 10, height: 10)
        let document = EditorDocument(baseImage: image)
        let annotation = makeArrow()
        document.add(annotation)

        var newStyle = annotation.style
        newStyle.color = .blue
        var updated = annotation
        updated.style = newStyle
        document.update(updated)
        XCTAssertEqual(document.annotations.first?.style.color, .blue)

        document.undo()
        XCTAssertEqual(document.annotations.first?.style.color, .red)
    }
}

/// 视口转换。
final class CanvasViewportTests: XCTestCase {
    func testFittedCentersAndShrinks() {
        let viewport = CanvasViewport.fitted(
            imageSize: CGSize(width: 2000, height: 1000),
            in: CGSize(width: 1000, height: 800),
            padding: 40
        )
        // 可用 920×720 → zoom = min(920/2000, 720/1000) = 0.46
        XCTAssertEqual(viewport.zoom, 0.46, accuracy: 0.001)
        // 图像显示 920×460 → 水平居中 origin.x=(1000-920)/2=40；垂直 origin.y=(800-460)/2=170
        XCTAssertEqual(viewport.origin.x, 40, accuracy: 0.001)
        XCTAssertEqual(viewport.origin.y, 170, accuracy: 0.001)
    }

    func testFittedDoesNotUpscale() {
        let viewport = CanvasViewport.fitted(
            imageSize: CGSize(width: 100, height: 50),
            in: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.origin.x, 450, accuracy: 0.001)
    }

    func testPointConversionRoundTrip() {
        var viewport = CanvasViewport(zoom: 2.5, origin: CGPoint(x: 30, y: 10))
        let imagePoint = CGPoint(x: 12, y: -4)
        let viewPoint = viewport.viewPoint(forImagePoint: imagePoint)
        XCTAssertEqual(viewPoint, CGPoint(x: 30 + 30, y: 10 - 10))
        XCTAssertEqual(viewport.imagePoint(forViewPoint: viewPoint), imagePoint)

        viewport = viewport.panned(by: CGPoint(x: -100, y: 50))
        XCTAssertEqual(viewport.origin, CGPoint(x: -70, y: 60))
    }

    func testZoomedKeepsAnchorImagePoint() {
        let viewport = CanvasViewport(zoom: 1, origin: CGPoint(x: 100, y: 100))
        let anchor = CGPoint(x: 300, y: 260) // 图像点 (200, 160)
        let zoomed = viewport.zoomed(to: 2, around: anchor)
        XCTAssertEqual(zoomed.zoom, 2)
        // 锚点图像点不变
        let imagePoint = viewport.imagePoint(forViewPoint: anchor)
        let mappedBack = zoomed.viewPoint(forImagePoint: imagePoint)
        XCTAssertEqual(mappedBack.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(mappedBack.y, anchor.y, accuracy: 0.001)
    }

    func testZoomClamped() {
        let viewport = CanvasViewport(zoom: 1, origin: .zero)
        XCTAssertEqual(viewport.zoomed(to: 100, around: .zero).zoom, CanvasViewport.zoomRange.upperBound)
        XCTAssertEqual(viewport.zoomed(to: 0.001, around: .zero).zoom, CanvasViewport.zoomRange.lowerBound)
    }
}

/// 渲染合成管线（导出与显示一致性基础）。
final class AnnotationRendererTests: XCTestCase {
    func testComposeOutputSizeMatchesBase() {
        let base = CGImage.testImage(width: 200, height: 120)
        let annotations = [
            Annotation(type: .arrow, geometry: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 190, y: 110))),
            Annotation(type: .rectangle, geometry: .rect(CGRect(x: 10, y: 10, width: 50, height: 50))),
        ]
        let composed = AnnotationRenderer.compose(baseImage: base, annotations: annotations)
        XCTAssertNotNil(composed)
        XCTAssertEqual(composed?.width, 200)
        XCTAssertEqual(composed?.height, 120)
    }

    func testComposeWithoutAnnotationsProducesValidImage() {
        let base = CGImage.testImage(width: 64, height: 64, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let composed = AnnotationRenderer.compose(baseImage: base, annotations: [])
        XCTAssertNotNil(composed)
        XCTAssertEqual(composed?.width, 64)
    }

    /// 效果渲染缓存（ADR-014 优化）：同 key 命中、参数变化 miss。
    func testEffectRenderCacheKeysAndHit() {
        let base = CGImage.testImage(width: 200, height: 150)
        let id = UUID()
        let rect = CGRect(x: 10, y: 10, width: 80, height: 60)

        let keyA = AnnotationRenderer.EffectRenderCache.key(kind: "mosaic", annotationID: id, rect: rect, parameter: 16, base: base)
        let keyA2 = AnnotationRenderer.EffectRenderCache.key(kind: "mosaic", annotationID: id, rect: rect, parameter: 16, base: base)
        XCTAssertEqual(keyA, keyA2, "同参数同图 → 同 key")

        // 不同参数 / 不同标注 / 不同底图 → 不同 key
        XCTAssertNotEqual(keyA, AnnotationRenderer.EffectRenderCache.key(kind: "mosaic", annotationID: id, rect: rect, parameter: 8, base: base))
        XCTAssertNotEqual(keyA, AnnotationRenderer.EffectRenderCache.key(kind: "mosaic", annotationID: UUID(), rect: rect, parameter: 16, base: base))
        XCTAssertNotEqual(keyA, AnnotationRenderer.EffectRenderCache.key(kind: "mosaic", annotationID: id, rect: rect, parameter: 16, base: CGImage.testImage(width: 200, height: 150)))

        // 存取命中同一实例
        let image = CGImage.testImage(width: 40, height: 30)
        AnnotationRenderer.EffectRenderCache.cache.setObject(image, forKey: keyA)
        XCTAssertTrue(AnnotationRenderer.EffectRenderCache.cache.object(forKey: keyA) === image)
    }
}

/// 测试图像工具。
extension CGImage {
    static func testImage(width: Int, height: Int, color: CGColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
