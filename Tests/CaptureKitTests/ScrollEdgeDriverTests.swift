import CoreGraphics
import XCTest

@testable import CaptureKit

/// 鼠标驱动滚动（长截图会话）纯函数单测。
final class ScrollEdgeDriverTests: XCTestCase {
    private let region = CGRect(x: 100, y: 100, width: 400, height: 400)

    func testMiddleOfRegionDoesNotScroll() {
        let plan = ScrollEdgeDriver.plan(mouse: CGPoint(x: 300, y: 300), region: region)
        XCTAssertEqual(plan.pixels, 0)
    }

    func testOutsideRegionDoesNotScroll() {
        XCTAssertEqual(ScrollEdgeDriver.plan(mouse: CGPoint(x: 50, y: 300), region: region).pixels, 0)
        XCTAssertEqual(ScrollEdgeDriver.plan(mouse: CGPoint(x: 300, y: 50), region: region).pixels, 0)
    }

    func testBottomEdgeScrollsDownFasterNearEdge() {
        let near = ScrollEdgeDriver.plan(mouse: CGPoint(x: 300, y: region.minY + 5), region: region)
        let far = ScrollEdgeDriver.plan(mouse: CGPoint(x: 300, y: region.minY + 80), region: region)
        XCTAssertGreaterThan(near.pixels, 0, "下边缘应向下滚（正数）")
        XCTAssertGreaterThan(far.pixels, 0)
        XCTAssertGreaterThan(near.pixels, far.pixels, "越靠边越快")
        XCTAssertLessThanOrEqual(near.pixels, 60)
    }

    func testTopEdgeScrollsUp() {
        let plan = ScrollEdgeDriver.plan(mouse: CGPoint(x: 300, y: region.maxY - 5), region: region)
        XCTAssertLessThan(plan.pixels, 0, "上边缘应向上滚（负数）")
    }

    func testLocationIsMousePoint() {
        let mouse = CGPoint(x: 250, y: region.minY + 10)
        let plan = ScrollEdgeDriver.plan(mouse: mouse, region: region)
        XCTAssertEqual(plan.location, mouse)
    }

    func testZeroSizeRegionIsSafe() {
        let plan = ScrollEdgeDriver.plan(mouse: .zero, region: .zero)
        XCTAssertEqual(plan.pixels, 0)
    }
}
