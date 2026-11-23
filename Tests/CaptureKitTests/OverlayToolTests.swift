import CoreGraphics
import XCTest

@testable import CaptureKit

/// 一体化工具栏 + 模式意图纯逻辑单测。
final class OverlayToolTests: XCTestCase {
    func testLineWidthValues() {
        XCTAssertEqual(OverlayLineWidth.thin.value, 2)
        XCTAssertEqual(OverlayLineWidth.medium.value, 4)
        XCTAssertEqual(OverlayLineWidth.thick.value, 8)
    }

    func testNearestWidthMapping() {
        XCTAssertEqual(OverlayLineWidth.nearest(to: 1), .thin)
        XCTAssertEqual(OverlayLineWidth.nearest(to: 3), .thin)
        XCTAssertEqual(OverlayLineWidth.nearest(to: 4), .medium)
        XCTAssertEqual(OverlayLineWidth.nearest(to: 6.1), .thick)
        XCTAssertEqual(OverlayLineWidth.nearest(to: 20), .thick)
    }

    @MainActor
    func testActiveToolNilMeansSelect() {
        let model = OverlaySelectionModel()
        XCTAssertNil(model.activeTool, "默认无工具 = 选择（拖动移动选区）")
        model.activeTool = .arrow
        XCTAssertEqual(model.activeTool, .arrow)
    }

    func testCaptureIntentDisplayNames() {
        XCTAssertEqual(OverlaySelectionModel.CaptureIntent.screenshot.displayName, "截图")
        XCTAssertEqual(OverlaySelectionModel.CaptureIntent.scroll.displayName, "滚动截图")
        XCTAssertEqual(OverlaySelectionModel.CaptureIntent.record.displayName, "录屏")
        XCTAssertEqual(OverlaySelectionModel.CaptureIntent.ocr.displayName, "文字识别")
    }

    // MARK: - 意图路由

    func testRouterScreenshotWithoutAnnotationsCopies() {
        let result = OverlayFinishRouter.result(
            intent: .screenshot,
            selection: CGRect(x: 1, y: 2, width: 100, height: 50),
            annotations: []
        )
        guard case .region(let rect, let action) = result else {
            return XCTFail("应为普通复制")
        }
        XCTAssertEqual(rect, CGRect(x: 1, y: 2, width: 100, height: 50))
        XCTAssertEqual(action, .copy)
    }

    func testRouterScreenshotWithAnnotationsComposes() {
        let annotation = Annotation(type: .arrow, geometry: .arrow(from: .zero, to: CGPoint(x: 10, y: 10)))
        let result = OverlayFinishRouter.result(
            intent: .screenshot,
            selection: CGRect(x: 0, y: 0, width: 100, height: 100),
            annotations: [annotation]
        )
        guard case .regionAnnotated(_, let annotations) = result else {
            return XCTFail("应为合成导出")
        }
        XCTAssertEqual(annotations, [annotation])
    }

    func testRouterRoutesOtherIntents() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        guard case .scrollRegion(let scrollRect) = OverlayFinishRouter.result(intent: .scroll, selection: rect, annotations: []) else {
            return XCTFail("滚动意图 → scrollRegion")
        }
        XCTAssertEqual(scrollRect, rect)

        guard case .recordRegion(let recordRect, let mode) = OverlayFinishRouter.result(intent: .record, selection: rect, annotations: []) else {
            return XCTFail("录屏意图 → recordRegion")
        }
        XCTAssertEqual(recordRect, rect)
        XCTAssertEqual(mode, .video)

        guard case .recognizeRegion(let ocrRect) = OverlayFinishRouter.result(intent: .ocr, selection: rect, annotations: []) else {
            return XCTFail("文字识别意图 → recognizeRegion")
        }
        XCTAssertEqual(ocrRect, rect)
    }
}
