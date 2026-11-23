import AppKit
import CoreGraphics
import XCTest

@testable import CaptureKit

/// OCR（Vision）真实识别测试 + 相关设置。
final class OCRTests: XCTestCase {
    /// 渲染一段清晰黑字白底文本 → Vision 识别。
    func testRecognizesRenderedText() async throws {
        let image = Self.renderText("Hello CaptureKit 12345")
        let text = try await OCRService.recognizeText(in: image)
        // 宽松断言：至少识别出关键词之一（渲染抗锯齿差异）
        let lower = text.lowercased()
        let hit = lower.contains("hello") || lower.contains("capturekit") || lower.contains("12345")
        XCTAssertTrue(hit, "识别结果未包含关键词：\"\(text)\"")
    }

    func testRecognizesMultiline() async throws {
        let image = Self.renderText("ABC\nDEF")
        let text = try await OCRService.recognizeText(in: image)
        XCTAssertFalse(text.isEmpty)
    }

    func testBlankImageReturnsEmptyOrWhitespace() async throws {
        let image = CGImage.testImage(width: 100, height: 60, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let text = try await OCRService.recognizeText(in: image)
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testOCRSettingsDecoding() throws {
        let legacy = #"{}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.ocr.enabled, "OCR 默认开启")
    }

    /// 用 NSAttributedString 渲染测试图像。
    private static func renderText(_ string: String) -> CGImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        let imageSize = CGSize(width: ceil(size.width) + 40, height: ceil(size.height) + 30)

        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        (string as NSString).draw(at: CGPoint(x: 20, y: 15), withAttributes: attributes)
        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("cannot render test image")
        }
        return cgImage
    }
}
