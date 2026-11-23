import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// CVPixelBuffer 区域裁剪（区域录制实现：整屏 SCStream + 写入前裁剪）。
/// 避免依赖 SCStreamConfiguration 区域裁剪 API 的版本差异（ADR-015）。
enum PixelBufferCropper {
    /// CIContext 复用（CIImage → CGImage 转换）。
    private static let ciContext = CIContext()

    /// CVPixelBuffer → CGImage（CIImage 路径，SDK 兼容）。
    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// 裁剪像素缓冲。
    /// - Parameters:
    ///   - source: 源缓冲（BGRA）。
    ///   - pixelRect: 像素坐标矩形（原点在左上，与 CGImage 一致）。
    static func crop(_ source: CVPixelBuffer, toPixelRect rect: CGRect) -> CVPixelBuffer? {
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width >= 2, height >= 2,
              width <= CVPixelBufferGetWidth(source), height <= CVPixelBufferGetHeight(source)
        else { return nil }

        guard let image = cgImage(from: source) else { return nil }
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2,
              let cropped = image.cropping(to: clamped)
        else { return nil }

        var destination: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clamped.width), Int(clamped.height),
            CVPixelBufferGetPixelFormatType(source),
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &destination
        )
        guard let dest = destination else { return nil }

        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(dest),
            width: Int(clamped.width), height: Int(clamped.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(dest),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: clamped.width, height: clamped.height))
        return dest
    }

    /// 用目标像素缓冲重造 CMSampleBuffer（继承原 PTS）。
    static func sampleBuffer(from buffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    /// 区域 rect（全局 AppKit 逻辑坐标）→ 帧像素坐标（原点左上）。
    static func pixelRect(forRegion region: CGRect,
                          displayFrame: CGRect,
                          framePixelSize: CGSize) -> CGRect {
        let scaleX = framePixelSize.width / displayFrame.width
        let scaleY = framePixelSize.height / displayFrame.height
        return CGRect(
            x: (region.minX - displayFrame.minX) * scaleX,
            y: (displayFrame.maxY - region.maxY) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        )
    }
}
