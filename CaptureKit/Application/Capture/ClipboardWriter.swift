import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板写入服务。
/// 写入 PNG representation，保留无损数据；同时提供 TIFF 以兼容旧应用。
enum ClipboardWriter {
    /// 将 CGImage 以 PNG+TIFF 写入系统剪贴板。
    static func copy(_ image: CGImage) throws {
        try copy(image, to: .general)
    }

    /// 写入指定 pasteboard（用于测试，避免污染系统剪贴板）。
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()

        guard let pngData = pngData(from: image),
              let tiffData = tiffData(from: image)
        else {
            throw CaptureKitError.clipboardWriteFailed
        }

        pasteboard.setData(pngData, forType: .png)
        pasteboard.setData(tiffData, forType: .tiff)
        Log.clipboard.info("Image copied to clipboard (\(image.width)×\(image.height))")
    }

    static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func tiffData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:])
    }
}
