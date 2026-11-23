import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// GIF 流式编码器（design.md §8.6）：ImageIO 增量写文件，不长期驻留全部帧。
final class GIFEncoder {
    enum GIFError: Error {
        case cannotCreateDestination
        case encodeFailure
    }

    let outputURL: URL
    private let destination: CGImageDestination
    private let frameDelay: Double
    private let maxPixelWidth: Int
    private(set) var appendedFrameCount = 0

    /// - Parameters:
    ///   - fps: 采集帧率。
    ///   - playbackSpeed: 播放速度（1.0 正常；2.0 两倍速；0.5 半速）。帧延迟 = 1/(fps×speed)。
    init(outputURL: URL, fps: Int, maxPixelWidth: Int = 720, playbackSpeed: Double = 1.0) throws {
        self.outputURL = outputURL
        let speed = min(4.0, max(0.25, playbackSpeed))
        // GIF 延迟下限 0.02s（1/100s 精度下低于此值会被浏览器钳到 0.1s）
        self.frameDelay = max(0.02, 1.0 / (Double(max(5, fps)) * speed))
        self.maxPixelWidth = max(120, maxPixelWidth)

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0, // 增量（数量未知）
            nil
        ) else {
            throw GIFError.cannotCreateDestination
        }
        // 全局调色板参数
        let gifProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFHasGlobalColorMap as String: true,
            ],
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        self.destination = destination
    }

    /// 追加一帧（自动等比缩放到最大宽度）。
    /// 输入帧 PTS 已由上层按帧率节流，这里统一使用固定帧延迟。
    func append(_ image: CGImage) throws {
        let scaled = Self.scaled(image: image, maxPixelWidth: maxPixelWidth)
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay,
            ],
        ]
        // CGImageDestinationAddImage 返回 Void；失败在 finalize 时体现
        CGImageDestinationAddImage(destination, scaled, frameProperties as CFDictionary)
        appendedFrameCount += 1
    }

    /// 完成编码（文件落盘）。
    func finish() throws {
        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.encodeFailure
        }
        Log.recording.info("GIF finished: \(self.outputURL.lastPathComponent, privacy: .public) (\(self.appendedFrameCount) frames)")
    }

    /// 取消并删除半成品。
    func cancel() {
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 等比缩小（超过最大宽度才缩放；避免不必要的重绘）。
    static func scaled(image: CGImage, maxPixelWidth: Int) -> CGImage {
        guard image.width > maxPixelWidth else { return image }
        let scale = CGFloat(maxPixelWidth) / CGFloat(image.width)
        let targetWidth = maxPixelWidth
        let targetHeight = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        // CGImage 首行在顶；位图上下文 draw 直接正立写入
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }
}
