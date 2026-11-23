import CoreGraphics
import Foundation

/// 采样到的像素颜色（放大镜取色）。
struct PixelColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// `#RRGGBB` 大写十六进制。
    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// `rgb(r, g, b)` 文本。
    var rgbText: String {
        "rgb(\(red), \(green), \(blue))"
    }
}

/// 从屏幕快照读取单点颜色（Overlay 放大镜取色数据源）。
///
/// 逻辑点 → 像素矩形经 `ScreenGeometry` 统一转换（y 翻转 + 实际缩放），
/// 裁剪 1×1 像素绘制到 RGBA 位图读值；不依赖 `backingScaleFactor`。
enum PixelColorReader {
    /// 在快照列表中找到包含该点的显示器并采样。
    static func color(at globalPoint: CGPoint, snapshots: [ScreenSnapshot]) -> PixelColor? {
        guard let snapshot = snapshots.first(where: { $0.frame.contains(globalPoint) }) else {
            return nil
        }
        return color(at: globalPoint, snapshot: snapshot)
    }

    /// 从单个屏幕快照采样全局逻辑点处的颜色。
    static func color(at globalPoint: CGPoint, snapshot: ScreenSnapshot) -> PixelColor? {
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let pixelRect = ScreenGeometry.pixelRect(
            logicalRect: CGRect(origin: globalPoint, size: CGSize(width: 1, height: 1)),
            displayFrame: snapshot.frame,
            imagePixelSize: imageSize
        )
        guard let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: imageSize),
              let cropped = snapshot.image.cropping(to: clamped)
        else { return nil }

        // 1×1 RGBA8 位图读回像素值
        var pixels = [UInt8](repeating: 0, count: 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return PixelColor(red: pixels[0], green: pixels[1], blue: pixels[2])
    }
}
