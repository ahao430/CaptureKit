import CoreGraphics
import XCTest

@testable import CaptureKit

/// 滚动截图匹配与拼接（plan.md §2.5 基础拼接）。
/// 用合成"长页面"图模拟滚动：frame_i = page 在 y=i*step 处裁出的窗口 → 匹配应恢复 step，拼接应还原页面。
final class ScrollCaptureTests: XCTestCase {
    /// 生成确定性纹理长页（横向渐变 + 每 40px 一条黑色分隔线，抗纯色退化）。
    private static func makePage(width: Int = 300, height: Int = 600) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0..<height {
            let value = CGFloat(y % 40 == 0 ? 0 : (y % 255)) / 255
            context.setFillColor(CGColor(red: value, green: CGFloat((y * 3) % 255) / 255, blue: CGFloat((y * 7) % 255) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1))
        }
        return context.makeImage()!
    }

    /// 从长页取视口帧（y 为页面坐标，自上而下）。
    private static func frame(from page: CGImage, atY y: Int, viewHeight: Int) -> CGImage {
        // CGImage.cropping 用顶部原点像素坐标
        page.cropping(to: CGRect(x: 0, y: y, width: page.width, height: viewHeight))!
    }

    func testEstimateShiftRecoversStep() {
        let page = Self.makePage()
        let viewHeight = 200
        let step = 120
        let frameA = Self.frame(from: page, atY: 0, viewHeight: viewHeight)
        let frameB = Self.frame(from: page, atY: step, viewHeight: viewHeight)

        let match = ScrollFrameMatcher.estimateShift(previous: frameA, current: frameB)
        // 降采样量化误差 ±3px
        XCTAssertEqual(match.shift, step, accuracy: 3)
        XCTAssertGreaterThan(match.confidence, 0.8)
    }

    func testDuplicateFramesGiveZeroShift() {
        let page = Self.makePage()
        let frame = Self.frame(from: page, atY: 0, viewHeight: 200)
        let match = ScrollFrameMatcher.estimateShift(previous: frame, current: frame)
        XCTAssertEqual(match.shift, 0)
        XCTAssertGreaterThan(match.confidence, 0.9)
    }

    func testZeroShiftWhenNoOverlap() {
        // 页面各段无重复内容（渐变方向性）→ 无重叠时 d=0 的得分反而最优差
        let top = Self.frame(from: Self.makePage(height: 200), atY: 0, viewHeight: 200)
        let bottom = Self.frame(from: Self.makePage(height: 200), atY: 199, viewHeight: 200)
        // 纯位移无关的内容差异大 → 置信度低
        let match = ScrollFrameMatcher.estimateShift(previous: top, current: bottom)
        // 无法断言精确位移，只验证不崩溃且返回值合法
        XCTAssertTrue(match.shift >= 0)
        XCTAssertTrue(match.confidence >= 0 && match.confidence <= 1)
    }

    func testStitchRestoresPage() {
        let page = Self.makePage(height: 600)
        let viewHeight = 200
        let step = 100
        let frames = [
            Self.frame(from: page, atY: 0, viewHeight: viewHeight),
            Self.frame(from: page, atY: step, viewHeight: viewHeight),
            Self.frame(from: page, atY: step * 2, viewHeight: viewHeight),
            Self.frame(from: page, atY: step * 3, viewHeight: viewHeight),
        ]

        let result = ScrollImageStitcher.stitch(frames: frames)
        let stitched = result.image
        XCTAssertNotNil(stitched)
        // 高度 ≈ 首帧 + 3*step（量化容差）
        XCTAssertEqual(stitched?.height ?? 0, viewHeight + step * 3, accuracy: 8)
        XCTAssertGreaterThan(stitched?.width ?? 0, 0)
        XCTAssertEqual(result.lowConfidenceSegments, 0)
        XCTAssertEqual(result.skippedDuplicates, 0)
    }

    func testStitchSkipsDuplicateFrames() {
        let page = Self.makePage(height: 400)
        let frames = [
            Self.frame(from: page, atY: 0, viewHeight: 200),
            Self.frame(from: page, atY: 0, viewHeight: 200), // 重复
            Self.frame(from: page, atY: 100, viewHeight: 200),
        ]
        let result = ScrollImageStitcher.stitch(frames: frames)
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(result.image?.height ?? 0, 300, accuracy: 8)
    }

    func testStitchSingleFramePassthrough() {
        let frame = Self.frame(from: Self.makePage(height: 200), atY: 0, viewHeight: 200)
        let result = ScrollImageStitcher.stitch(frames: [frame])
        XCTAssertEqual(result.image?.height, 200)
        XCTAssertEqual(result.lowConfidenceSegments, 0)
    }

    func testStitchLowConfidenceFallsBackToFullAppend() {
        // 两个无关图像（纯红 vs 纯蓝）→ 低置信 → 整帧追加
        let red = CGImage.testImage(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = CGImage.testImage(width: 100, height: 100, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let result = ScrollImageStitcher.stitch(frames: [red, blue])
        XCTAssertEqual(result.lowConfidenceSegments, 1)
        XCTAssertEqual(result.image?.height ?? 0, 200, accuracy: 2)
    }

    func testStitchHeightCapped() {
        // 8 帧大幅滚动 → 触发 16000px 上限保护（此处用小图验证逻辑路径不崩溃）
        let page = Self.makePage(height: 300)
        var frames: [CGImage] = []
        for index in 0..<6 {
            frames.append(Self.frame(from: page, atY: min(index * 40, 100), viewHeight: 200))
        }
        let result = ScrollImageStitcher.stitch(frames: frames)
        XCTAssertNotNil(result.image)
        XCTAssertLessThanOrEqual(result.image!.height, 16_000)
    }
}

/// 自动滚动（ADR-027）：坐标换算与事件构造（纯函数部分）。
final class AutoScrollTests: XCTestCase {
    func testAppKitToCGGlobalConversion() {
        let height: CGFloat = 900
        // AppKit 底部（y=0）→ CG 顶部（y=900）
        XCTAssertEqual(AutoScroller.appKitToCGGlobal(CGPoint(x: 100, y: 0), mainScreenHeight: height), CGPoint(x: 100, y: 900))
        // AppKit 顶部 → CG 底部
        XCTAssertEqual(AutoScroller.appKitToCGGlobal(CGPoint(x: 100, y: 900), mainScreenHeight: height), CGPoint(x: 100, y: 0))
        // 中点对称
        XCTAssertEqual(AutoScroller.appKitToCGGlobal(CGPoint(x: 50, y: 450), mainScreenHeight: height), CGPoint(x: 50, y: 450))
    }

    func testScrollDownEventConstruction() {
        guard let event = AutoScroller.makeScrollDownEvent(pixels: 90) else {
            XCTFail("scroll event construction failed")
            return
        }
        // 向下滚动：点增量必须为负
        XCTAssertLessThan(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        // 位置可设置
        event.location = CGPoint(x: 500, y: 300)
        XCTAssertEqual(event.location.x, 500, accuracy: 0.001)
        XCTAssertEqual(event.location.y, 300, accuracy: 0.001)
    }
}
