import XCTest

@testable import CaptureKit

/// 一体化工具栏：线宽三档与工具枚举纯逻辑单测。
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
    func testToolSelectFlag() {
        XCTAssertTrue(OverlaySelectionModel.OverlayTool.select.isSelect)
        XCTAssertFalse(OverlaySelectionModel.OverlayTool.annotate(.arrow).isSelect)
    }
}
