import CoreGraphics
import XCTest

@testable import CaptureKit

/// 贴图缩放 / 透明度纯计算单测。
final class PinnedImageMathTests: XCTestCase {
    // MARK: - 缩放

    func testZoomInScalesProportionally() {
        let size = CGSize(width: 200, height: 100)
        let zoomed = PinnedImageMath.zoomedSize(current: size, delta: 1, maxSide: 6000)
        // 1.1x 等比
        XCTAssertEqual(zoomed.width / zoomed.height, 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.width, 220, accuracy: 0.001)
    }

    func testZoomOutClampsToMinSide() {
        let size = CGSize(width: 200, height: 100)
        // 大幅缩小：最短边（100）不低于 minSide 80
        let zoomed = PinnedImageMath.zoomedSize(current: size, delta: -50, minSide: 80, maxSide: 6000)
        XCTAssertEqual(min(zoomed.width, zoomed.height), 80, accuracy: 0.001)
        // 等比保持
        XCTAssertEqual(zoomed.width / zoomed.height, 2, accuracy: 0.001)
    }

    func testZoomInClampsToMaxSide() {
        let size = CGSize(width: 200, height: 100)
        let zoomed = PinnedImageMath.zoomedSize(current: size, delta: 100, minSide: 80, maxSide: 800)
        XCTAssertEqual(max(zoomed.width, zoomed.height), 800, accuracy: 0.001)
        XCTAssertEqual(zoomed.width / zoomed.height, 2, accuracy: 0.001)
    }

    func testZeroSizeUnchanged() {
        let zoomed = PinnedImageMath.zoomedSize(current: .zero, delta: 3, maxSide: 6000)
        XCTAssertEqual(zoomed, .zero)
    }

    // MARK: - 透明度

    func testOpacityStepUp() {
        XCTAssertEqual(PinnedImageMath.steppedOpacity(current: 0.5, delta: 1), 0.55, accuracy: 0.001)
    }

    func testOpacityStepDownClampsToLowerBound() {
        XCTAssertEqual(PinnedImageMath.steppedOpacity(current: 0.2, delta: -10), 0.15, accuracy: 0.001)
    }

    func testOpacityClampsToOne() {
        XCTAssertEqual(PinnedImageMath.steppedOpacity(current: 0.99, delta: 10), 1, accuracy: 0.001)
    }
}
