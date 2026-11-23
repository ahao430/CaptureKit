import AppKit
import CoreGraphics
import XCTest

@testable import CaptureKit

final class ClipboardWriterTests: XCTestCase {
    private func makeSolidImage(width: Int = 8, height: Int = 6, color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)) throws -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("无法创建测试图像")
        }
        return image
    }

    func testCopyWritesPNGAndTIFF() throws {
        let image = try makeSolidImage()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        try ClipboardWriter.copy(image, to: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.png), "缺少 PNG representation")
        XCTAssertTrue(types.contains(.tiff), "缺少 TIFF representation")

        let pngData = pasteboard.data(forType: .png)
        XCTAssertNotNil(pngData)
        // PNG 魔数
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        XCTAssertEqual(Array(pngData!.prefix(4)), magic)
    }

    func testPNGDataEncodesValidImage() throws {
        let image = try makeSolidImage(width: 16, height: 12)
        let data = try XCTUnwrap(ClipboardWriter.pngData(from: image))
        XCTAssertGreaterThan(data.count, 0)

        // 解码回来尺寸一致
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 12)
    }
}
