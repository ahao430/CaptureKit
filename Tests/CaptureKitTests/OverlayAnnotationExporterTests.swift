import CoreGraphics
import XCTest

@testable import CaptureKit

/// Overlay 标注 → 像素坐标缩放的单测（几何逐轴映射 + 样式参数等比缩放）。
final class OverlayAnnotationExporterTests: XCTestCase {
    private let selectionSize = CGSize(width: 200, height: 100)
    // x 轴 2x、y 轴 4x（跨 DPI/异形缩放的极端用例）
    private let imageSize = CGSize(width: 400, height: 400)

    func testRectGeometryScalesPerAxis() {
        let annotation = Annotation(type: .rectangle, geometry: .rect(CGRect(x: 10, y: 20, width: 100, height: 50)))
        let scaled = OverlayAnnotationExporter.scale(
            annotations: [annotation],
            selectionSize: selectionSize,
            imageSize: imageSize
        )
        XCTAssertEqual(scaled.count, 1)
        guard case .rect(let rect) = scaled[0].geometry else {
            return XCTFail("几何类型不应改变")
        }
        XCTAssertEqual(rect.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 80, accuracy: 0.001)
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001)
    }

    func testArrowEndpointsScale() {
        let annotation = Annotation(type: .arrow, geometry: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100)))
        let scaled = OverlayAnnotationExporter.scale(annotations: [annotation], selectionSize: selectionSize, imageSize: imageSize)
        guard case .arrow(let from, let to) = scaled[0].geometry else {
            return XCTFail("几何类型不应改变")
        }
        XCTAssertEqual(from.x, 0, accuracy: 0.001)
        XCTAssertEqual(from.y, 0, accuracy: 0.001)
        XCTAssertEqual(to.x, 400, accuracy: 0.001)
        XCTAssertEqual(to.y, 400, accuracy: 0.001)
    }

    func testBrushPointsScale() {
        let annotation = Annotation(type: .brush, geometry: .brush(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)]))
        let scaled = OverlayAnnotationExporter.scale(annotations: [annotation], selectionSize: selectionSize, imageSize: imageSize)
        guard case .brush(let points) = scaled[0].geometry else {
            return XCTFail("几何类型不应改变")
        }
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 20, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 40, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 100, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 120, accuracy: 0.001)
    }

    func testStyleParametersScaleByYAxis() {
        var annotation = Annotation(type: .rectangle, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        annotation.style = AnnotationStyle(
            color: .red, lineWidth: 4, isFilled: false, fontSize: 18,
            mosaicGranularity: 16, blurRadius: 15
        )
        let scaled = OverlayAnnotationExporter.scale(annotations: [annotation], selectionSize: selectionSize, imageSize: imageSize)
        // y 轴 4 倍
        XCTAssertEqual(scaled[0].style.lineWidth, 16)
        XCTAssertEqual(scaled[0].style.fontSize, 72)
        XCTAssertEqual(scaled[0].style.mosaicGranularity, 64)
        XCTAssertEqual(scaled[0].style.blurRadius, 60)
        XCTAssertEqual(scaled[0].style.color, .red)
    }

    func testOrderAndIDsPreserved() {
        let a = Annotation(type: .rectangle, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let b = Annotation(type: .arrow, geometry: .arrow(from: .zero, to: CGPoint(x: 10, y: 10)))
        let scaled = OverlayAnnotationExporter.scale(annotations: [a, b], selectionSize: selectionSize, imageSize: imageSize)
        XCTAssertEqual(scaled.map(\.id), [a.id, b.id])
    }

    func testEmptySelectionReturnsEmpty() {
        let annotation = Annotation(type: .rectangle, geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertTrue(OverlayAnnotationExporter.scale(annotations: [annotation], selectionSize: .zero, imageSize: imageSize).isEmpty)
        XCTAssertTrue(OverlayAnnotationExporter.scale(annotations: [annotation], selectionSize: selectionSize, imageSize: .zero).isEmpty)
    }
}
