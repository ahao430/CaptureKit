import AVFoundation
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 内容文件存储（design.md §10.6）：
/// ~/Library/Application Support/CaptureKit/Content/{Images,Videos,GIFs,Clipboard}。
/// 写入先落临时文件再原子移动；数据库记录与文件写入失败不产生半记录（调用方顺序：先文件后库）。
final class ContentFileStore {
    enum StoreError: Error {
        case writeFailed(String)
    }

    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base.appendingPathComponent("CaptureKit/Content", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    /// 按日期分目录的子目录。
    private func directory(for kind: Kind) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let sub = rootURL
            .appendingPathComponent(kind.directoryName, isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    /// 原子写入并返回相对路径（相对 rootURL，便于迁移）。
    @discardableResult
    func save(data: Data, kind: Kind, fileExtension: String) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = "\(Int(Date().timeIntervalSince1970))-\(digest).\(fileExtension)"
        let destination = directory(for: kind).appendingPathComponent(name)
        let temporary = destination.appendingPathExtension("tmp")

        do {
            try data.write(to: temporary, options: .atomic)
            try? FileManager.default.removeItem(at: destination) // 同名覆盖（几乎不可能）
            try FileManager.default.moveItem(at: temporary, to: destination)
            return relativePath(for: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    func url(forRelativePath path: String) -> URL {
        // 防路径逃逸：只用最后组件拼接安全前缀
        let sanitized = path.replacingOccurrences(of: "..", with: "")
        return rootURL.appendingPathComponent(sanitized)
    }

    func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
    }

    func relativePath(for absolute: URL) -> String {
        absolute.path.replacingOccurrences(of: rootURL.path + "/", with: "")
    }

    /// 存储类别。
    enum Kind {
        case image       // 截图（PNG）
        case video
        case gif
        case clipboard   // 剪贴板采集文件

        var directoryName: String {
            switch self {
            case .image: return "Images"
            case .video: return "Videos"
            case .gif: return "GIFs"
            case .clipboard: return "Clipboard"
            }
        }
    }
}

/// 缩略图生成（design.md §10.6：缩略图单独管理、异步生成）。
enum ThumbnailService {
    static let maxPixelWidth = 320

    /// 从图像数据生成缩略图数据（PNG）。
    static func thumbnailData(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return thumbnailData(from: image)
    }

    static func thumbnailData(from image: CGImage) -> Data? {
        guard image.width > maxPixelWidth else {
            return ClipboardWriter.pngData(from: image)
        }
        let scale = CGFloat(maxPixelWidth) / CGFloat(image.width)
        let width = maxPixelWidth
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return ClipboardWriter.pngData(from: scaled)
    }

    /// 视频首帧缩略图（AVAssetImageGenerator）。
    static func videoThumbnail(videoURL: URL) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelWidth, height: maxPixelWidth)
        let time = CMTime(seconds: min(0.1, duration.seconds / 2), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return ClipboardWriter.pngData(from: cgImage)
    }
}
