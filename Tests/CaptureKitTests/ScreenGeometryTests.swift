import XCTest

@testable import CaptureKit

/// 坐标转换单元测试（design.md §17.1 优先测试项：坐标转换）。
/// 覆盖：单屏 Retina、非零原点（多屏副屏）、负坐标（主屏左侧外接屏）、y 轴翻转、越界裁剪。
final class ScreenGeometryTests: XCTestCase {
    // 主屏：逻辑 1440×900，Retina 2x → 图像 2880×1800
    private let mainDisplayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let mainImageSize = CGSize(width: 2880, height: 1800)

    func testPixelRectFullDisplay() {
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: mainDisplayFrame,
            displayFrame: mainDisplayFrame,
            imagePixelSize: mainImageSize
        )
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 2880, height: 1800))
    }

    func testPixelRectBottomLeftQuadrant() {
        // 逻辑 (0,0)-(720,450)：AppKit 左下象限 → 图像坐标应为左下（y 靠近图像底部）
        let logical = CGRect(x: 0, y: 0, width: 720, height: 450)
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: logical,
            displayFrame: mainDisplayFrame,
            imagePixelSize: mainImageSize
        )
        // y 翻转：逻辑 y=0（屏幕底部）→ 图像 y = (900-450)*2 = 900
        XCTAssertEqual(pixel, CGRect(x: 0, y: 900, width: 1440, height: 900))
    }

    func testPixelRectTopRightQuadrant() {
        let logical = CGRect(x: 720, y: 450, width: 720, height: 450)
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: logical,
            displayFrame: mainDisplayFrame,
            imagePixelSize: mainImageSize
        )
        XCTAssertEqual(pixel, CGRect(x: 1440, y: 0, width: 1440, height: 900))
    }

    func testPixelRectSecondaryDisplayWithPositiveOrigin() {
        // 副屏在主屏右侧：origin (1440, 0)，非 Retina 1x
        let secondaryFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let secondaryImage = CGSize(width: 1920, height: 1080)
        // 选副屏内 (100,200) 起 300×200
        let logical = CGRect(x: 1540, y: 200, width: 300, height: 200)
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: logical,
            displayFrame: secondaryFrame,
            imagePixelSize: secondaryImage
        )
        XCTAssertEqual(pixel, CGRect(x: 100, y: 680, width: 300, height: 200))
    }

    func testPixelRectNegativeOriginDisplay() {
        // 外接屏在主屏左侧：origin (-1920, 0)，Retina 2x
        let leftFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftImage = CGSize(width: 3840, height: 2160)
        // 选左屏左半：全局 (-1920, 0) 960×1080
        let logical = CGRect(x: -1920, y: 0, width: 960, height: 1080)
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: logical,
            displayFrame: leftFrame,
            imagePixelSize: leftImage
        )
        XCTAssertEqual(pixel, CGRect(x: 0, y: 0, width: 1920, height: 2160))
    }

    func testPixelRectNonUniformScale() {
        // SCK 输出与请求尺寸不一致（如 1.5x 缩放）：比例由实际图像推导
        let displayFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let image = CGSize(width: 3000, height: 3000) // 3x
        let logical = CGRect(x: 100, y: 100, width: 200, height: 300)
        let pixel = ScreenGeometry.pixelRect(
            logicalRect: logical,
            displayFrame: displayFrame,
            imagePixelSize: image
        )
        XCTAssertEqual(pixel, CGRect(x: 300, y: 1800, width: 600, height: 900))
    }

    // MARK: - 裁剪

    func testClampedPixelRectInsideBounds() {
        let rect = CGRect(x: 10.2, y: 20.7, width: 100.5, height: 50.9)
        let clamped = ScreenGeometry.clampedPixelRect(rect, in: CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(clamped)
        // 整数像素对齐：integral 向外取整（minX=floor, maxX=ceil）
        XCTAssertEqual(clamped?.minX, 10)
        XCTAssertEqual(clamped?.minY, 20)
        XCTAssertEqual(clamped?.width, 101)
        XCTAssertEqual(clamped?.height, 52)
    }

    func testClampedPixelRectPartiallyOutside() {
        let rect = CGRect(x: -10, y: -10, width: 100, height: 100)
        let clamped = ScreenGeometry.clampedPixelRect(rect, in: CGSize(width: 50, height: 50))
        // 负起点裁剪到 0
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    func testClampedPixelRectFullyOutside() {
        let rect = CGRect(x: 500, y: 500, width: 100, height: 100)
        let clamped = ScreenGeometry.clampedPixelRect(rect, in: CGSize(width: 100, height: 100))
        XCTAssertNil(clamped)
    }

    // MARK: - 显示器选择

    func testBestDisplayPicksLargestIntersection() {
        let main = (displayID: CGDirectDisplayID(1), frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let secondary = (displayID: CGDirectDisplayID(2), frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        // 选区大部分在副屏
        let rect = CGRect(x: 1200, y: 100, width: 1000, height: 500)
        XCTAssertEqual(ScreenGeometry.bestDisplay(for: rect, candidates: [main, secondary]), 2)

        // 选区完全在主屏
        let rect2 = CGRect(x: 100, y: 100, width: 500, height: 500)
        XCTAssertEqual(ScreenGeometry.bestDisplay(for: rect2, candidates: [main, secondary]), 1)

        // 不与任何屏相交
        let rect3 = CGRect(x: -5000, y: -5000, width: 100, height: 100)
        XCTAssertNil(ScreenGeometry.bestDisplay(for: rect3, candidates: [main, secondary]))
    }

    // MARK: - 窗口命中

    func testWindowHitPicksSmallestContainingWindow() {
        let desktop = (windowID: CGWindowID(10), frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let app1 = (windowID: CGWindowID(11), frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let app2 = (windowID: CGWindowID(12), frame: CGRect(x: 300, y: 300, width: 300, height: 200))

        // 点同时命中三个窗口 → 取面积最小的 app2
        let point = CGPoint(x: 400, y: 400)
        XCTAssertEqual(ScreenGeometry.window(at: point, candidates: [desktop, app1, app2]), 12)

        // 只命中大窗口
        let point2 = CGPoint(x: 150, y: 150)
        XCTAssertEqual(ScreenGeometry.window(at: point2, candidates: [desktop, app1, app2]), 11)

        // 不命中
        let point3 = CGPoint(x: -100, y: -100)
        XCTAssertNil(ScreenGeometry.window(at: point3, candidates: [desktop, app1, app2]))
    }

    // MARK: - 选区控制点（Phase 1）

    private let selection = CGRect(x: 100, y: 100, width: 200, height: 150)

    func testHandlePositions() {
        XCTAssertEqual(SelectionHandle.topLeft.position(on: selection), CGPoint(x: 100, y: 250))
        XCTAssertEqual(SelectionHandle.top.position(on: selection), CGPoint(x: 200, y: 250))
        XCTAssertEqual(SelectionHandle.topRight.position(on: selection), CGPoint(x: 300, y: 250))
        XCTAssertEqual(SelectionHandle.right.position(on: selection), CGPoint(x: 300, y: 175))
        XCTAssertEqual(SelectionHandle.bottomRight.position(on: selection), CGPoint(x: 300, y: 100))
        XCTAssertEqual(SelectionHandle.bottom.position(on: selection), CGPoint(x: 200, y: 100))
        XCTAssertEqual(SelectionHandle.bottomLeft.position(on: selection), CGPoint(x: 100, y: 100))
        XCTAssertEqual(SelectionHandle.left.position(on: selection), CGPoint(x: 100, y: 175))
    }

    func testHandleHitTest() {
        // 精确命中角点
        XCTAssertEqual(
            ScreenGeometry.handle(at: CGPoint(x: 100, y: 250), of: selection),
            .topLeft
        )
        // 容差内命中
        XCTAssertEqual(
            ScreenGeometry.handle(at: CGPoint(x: 305, y: 100), of: selection, tolerance: 8),
            .bottomRight
        )
        // 超出容差
        XCTAssertNil(ScreenGeometry.handle(at: CGPoint(x: 320, y: 100), of: selection, tolerance: 8))
        // 中心不命中任何控制点
        XCTAssertNil(ScreenGeometry.handle(at: CGPoint(x: 200, y: 175), of: selection))
    }

    func testResizeCornerKeepsOppositeCornerFixed() {
        // 拖左上角 → 右下角 (300,100) 固定
        let resized = ScreenGeometry.resizeRect(selection, handle: .topLeft, to: CGPoint(x: 50, y: 300))
        XCTAssertEqual(resized, CGRect(x: 50, y: 100, width: 250, height: 200))
    }

    func testResizeEdgeMovesOnlyOneAxis() {
        // 拖右边 → 仅 x 变化
        let resized = ScreenGeometry.resizeRect(selection, handle: .right, to: CGPoint(x: 350, y: 999))
        XCTAssertEqual(resized, CGRect(x: 100, y: 100, width: 250, height: 150))
        // 拖上边 → 仅 y 变化
        let resized2 = ScreenGeometry.resizeRect(selection, handle: .top, to: CGPoint(x: 999, y: 280))
        XCTAssertEqual(resized2, CGRect(x: 100, y: 100, width: 200, height: 180))
    }

    func testResizeFlipNormalizesRect() {
        // 拖右上角越过左边界 → 翻转为归一化矩形
        let resized = ScreenGeometry.resizeRect(selection, handle: .topRight, to: CGPoint(x: 40, y: 280))
        XCTAssertEqual(resized, CGRect(x: 40, y: 100, width: 60, height: 180))
    }

    func testMovedRect() {
        let moved = ScreenGeometry.movedRect(selection, dx: 10, dy: -5)
        XCTAssertEqual(moved, CGRect(x: 110, y: 95, width: 200, height: 150))
    }

    // MARK: - 窗口吸附

    func testSnappedPointSnapsToNearestEdges() {
        let windows = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 640, height: 600),
        ]
        // 距第一个窗口右缘（=第二窗口左缘 800）5pt → 吸附
        var p = ScreenGeometry.snappedPoint(CGPoint(x: 795, y: 300), toEdgesIn: windows, threshold: 6)
        XCTAssertEqual(p, CGPoint(x: 800, y: 300))

        // 距窗口上缘 3pt → 吸附到 y=600？(第一窗口 maxY=600)
        p = ScreenGeometry.snappedPoint(CGPoint(x: 400, y: 597), toEdgesIn: windows, threshold: 6)
        XCTAssertEqual(p, CGPoint(x: 400, y: 600))

        // 超出阈值不吸附
        p = ScreenGeometry.snappedPoint(CGPoint(x: 500, y: 500), toEdgesIn: windows, threshold: 6)
        XCTAssertEqual(p, CGPoint(x: 500, y: 500))
    }

    func testSnappedPointEmptyFrames() {
        let p = CGPoint(x: 123, y: 456)
        XCTAssertEqual(ScreenGeometry.snappedPoint(p, toEdgesIn: [], threshold: 6), p)
    }
}
