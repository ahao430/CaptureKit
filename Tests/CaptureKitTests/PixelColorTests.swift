import AppKit
import CoreGraphics
import XCTest

@testable import CaptureKit

/// 放大镜取色单元测试：格式化 + 快照采样（y 翻转 / 跨屏选择 / 越界 nil）。
final class PixelColorTests: XCTestCase {
    /// 4×2 图像：左半红右半蓝，frame 与图像 1:1 对应（AppKit 原点左下）。
    /// 注意用分量式 setFillColor（上下文本机色彩空间）：CGColor(red:) 构造的是
    /// 扩展 sRGB 色，绘制进 DeviceRGB 位图会触发色彩转换产生偏色（实测 255,38,0）。
    private func makeSplitSnapshot() -> ScreenSnapshot {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        return ScreenSnapshot(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 4, height: 2),
            image: context.makeImage()!
        )
    }

    // MARK: - 格式化

    func testHexFormatting() {
        XCTAssertEqual(PixelColor(red: 0xFF, green: 0x88, blue: 0x00).hex, "#FF8800")
        XCTAssertEqual(PixelColor(red: 0x0A, green: 0xBC, blue: 0xDE).hex, "#0ABCDE")
        XCTAssertEqual(PixelColor(red: 0, green: 0, blue: 0).hex, "#000000")
    }

    func testRGBTextFormatting() {
        XCTAssertEqual(PixelColor(red: 255, green: 136, blue: 0).rgbText, "rgb(255, 136, 0)")
    }

    // MARK: - 快照采样

    func testSampleLeftHalfIsRed() {
        let snapshot = makeSplitSnapshot()
        // AppKit (0.5, 0.5)：左下 → 图像像素 (0,0)（图像原点左上，y 翻转）
        let color = PixelColorReader.color(at: CGPoint(x: 0.5, y: 0.5), snapshot: snapshot)
        XCTAssertEqual(color, PixelColor(red: 255, green: 0, blue: 0))
    }

    func testSampleRightHalfIsBlue() {
        let snapshot = makeSplitSnapshot()
        let color = PixelColorReader.color(at: CGPoint(x: 3.5, y: 1.5), snapshot: snapshot)
        XCTAssertEqual(color, PixelColor(red: 0, green: 0, blue: 255))
    }

    func testSamplePicksContainingDisplay() {
        let snapshot = makeSplitSnapshot()
        // 另一块不含该点的"屏幕"排在前面，应被跳过
        let other = ScreenSnapshot(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 4, height: 2),
            image: snapshot.image
        )
        let color = PixelColorReader.color(at: CGPoint(x: 1.0, y: 1.0), snapshots: [other, snapshot])
        XCTAssertEqual(color, PixelColor(red: 255, green: 0, blue: 0))
    }

    func testSampleOutsideAllDisplaysReturnsNil() {
        let snapshot = makeSplitSnapshot()
        XCTAssertNil(PixelColorReader.color(at: CGPoint(x: 100, y: 100), snapshots: [snapshot]))
        XCTAssertNil(PixelColorReader.color(at: CGPoint(x: -5, y: 1), snapshots: [snapshot]))
    }

    // MARK: - 悬停放大镜显隐逻辑

    @MainActor
    func testShowsMagnifierStates() {
        let model = OverlaySelectionModel()
        // 无快照 → 不显示
        model.currentDragPoint = CGPoint(x: 1, y: 1)
        XCTAssertFalse(model.showsMagnifier)

        model.snapshots = [makeSplitSnapshot()]
        // 无选区悬停 → 显示（取色）
        XCTAssertTrue(model.showsMagnifier)

        // 有选区且非交互 → 不显示
        model.selection = CGRect(x: 0, y: 0, width: 2, height: 1)
        XCTAssertFalse(model.showsMagnifier)

        // 交互中（创建/调整/移动）→ 显示
        model.interaction = .creating(start: .zero)
        XCTAssertTrue(model.showsMagnifier)
        model.interaction = .resizing(handle: .bottomRight)
        XCTAssertTrue(model.showsMagnifier)

        // 无鼠标点 → 不显示
        model.interaction = .none
        model.selection = nil
        model.currentDragPoint = nil
        XCTAssertFalse(model.showsMagnifier)
    }

    // MARK: - 文本剪贴板

    func testCopyTextWritesString() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        ClipboardWriter.copyText("#FF8800", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "#FF8800")
    }

    func testCopyTextSkipsEmptyString() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        ClipboardWriter.copyText("", to: pasteboard)

        // 空串不应清掉已有内容
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
