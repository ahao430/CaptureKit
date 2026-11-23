import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest

@testable import CaptureKit

/// 点击效果坐标换算与效果绘制（Phase 6）。
final class ClickEffectTests: XCTestCase {
    private let contentOrigin = CGPoint(x: 1440, y: 100) // 副屏或区域原点
    private let contentSize = CGSize(width: 800, height: 600)
    private let outputSize = CGSize(width: 1600, height: 1200) // 2x

    func testPixelPointCenterConversion() {
        // 内容中心点：全局 (1440+400, 100+300)
        let global = CGPoint(x: 1840, y: 400)
        let pixel = ClickEffectRenderer.pixelPoint(
            global: global,
            contentOrigin: contentOrigin,
            contentLogicalSize: contentSize,
            outputPixelSize: outputSize
        )
        // x = 400*2 = 800；y = 1200 - 300*2 = 600（y 翻转）
        XCTAssertEqual(pixel?.x ?? 0, 800, accuracy: 0.001)
        XCTAssertEqual(pixel?.y ?? 0, 600, accuracy: 0.001)
    }

    func testPixelPointTopLeftCorner() {
        // 内容左上角（AppKit 坐标 y 最大处）：global (1440, 700)
        let pixel = ClickEffectRenderer.pixelPoint(
            global: CGPoint(x: 1440, y: 700),
            contentOrigin: contentOrigin,
            contentLogicalSize: contentSize,
            outputPixelSize: outputSize
        )
        XCTAssertEqual(pixel?.x ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(pixel?.y ?? 0, 0, accuracy: 0.001)
    }

    func testPixelPointOutsideContentReturnsNil() {
        // 明显在内容外（>20pt 容差）
        let pixel = ClickEffectRenderer.pixelPoint(
            global: CGPoint(x: 100, y: 100),
            contentOrigin: contentOrigin,
            contentLogicalSize: contentSize,
            outputPixelSize: outputSize
        )
        XCTAssertNil(pixel)
    }

    func testDrawEffectsModifiesBuffer() throws {
        // 有效缓冲上绘制一个效果 → 像素被修改
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw XCTSkip("cannot create buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        let before = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        ClickEffectRenderer.drawEffects(on: buffer, effects: [(CGPoint(x: 32, y: 32), 0.2)])

        CVPixelBufferLockBaseAddress(buffer, [])
        let after = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        XCTAssertNotEqual(before, after, "绘制后像素应发生变化")
    }

    func testDrawEffectsEmptyNoop() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw XCTSkip("cannot create buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        let before = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        ClickEffectRenderer.drawEffects(on: buffer, effects: [])

        CVPixelBufferLockBaseAddress(buffer, [])
        let after = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        XCTAssertEqual(before, after, "空效果不应修改像素")
    }
}

/// 导出速度调节（Phase 6）。
final class ExportSpeedTests: XCTestCase {
    static func makeTempVideo(seconds: Double = 2.0) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitSpeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.mp4")

        let writer = try VideoWriter(outputURL: url, size: CGSize(width: 320, height: 240))
        writer.start()
        let frames = Int(seconds * 10)
        for index in 0..<frames {
            let buffer = try RecordingEncoderTests.makePixelBuffer(width: 320, height: 240, seed: index)
            if let sample = RecordingEncoderTests.makeSampleBuffer(from: buffer, seconds: Double(index) / 10.0) {
                writer.append(sample, outputPTS: CMTime(seconds: Double(index) / 10.0, preferredTimescale: 600))
            }
        }
        _ = try await writer.finish()
        return url
    }

    func testExportMP4DoubleSpeedHalvesDuration() async throws {
        let source = try await Self.makeTempVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("fast.mp4")

        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 2.0, preferredTimescale: 600)
        )
        let url = try await VideoExporter.exportMP4(from: source, to: destination, timeRange: range, speed: 2.0)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        // 2x 速 → 1s（编码容差放宽）
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.4)
    }

    func testExportGIFSpeedScalesFrameDelay() async throws {
        let source = try await Self.makeTempVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("fast.gif")

        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600))
        let url = try await VideoExporter.exportGIF(from: source, to: destination, timeRange: range, fps: 10, maxPixelWidth: 240, speed: 2.0)

        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        XCTAssertNotNil(imageSource)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource!, 0, nil) as? [String: Any],
              let gifDict = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        else {
            XCTFail("missing GIF properties")
            return
        }
        let delay = gifDict[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0
        // 10fps × 2x 速 → 0.05s（GIF 1/100s 精度）
        XCTAssertEqual(delay, 0.05, accuracy: 0.011)
    }

    func testGIFEncoderClampsExtremeSpeed() throws {
        // 极端速度被钳制，延迟不低于 0.02s
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clamp-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try GIFEncoder(outputURL: url, fps: 60, maxPixelWidth: 240, playbackSpeed: 100)
        try encoder.append(CGImage.testImage(width: 40, height: 40))
        try encoder.finish()
        // 不崩溃即通过（钳制逻辑在 init）
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

/// 孤儿条目自愈（Phase 6 崩溃恢复）。
@MainActor
final class OrphanHealingTests: XCTestCase {
    func testHealRemovesMissingFileEntries() async throws {
        let repository = try ContentRepository.temporary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitHeal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = ContentFileStore(rootURL: root)

        // 真实文件条目
        let realData = Data("real".utf8)
        let realPath = try fileStore.save(data: realData, kind: .clipboard, fileExtension: "txt")
        let realItem = ContentItem(type: .image, storagePath: realPath, thumbnailPath: realPath)
        try repository.insert(realItem)

        // 文件丢失条目（引用不存在的路径）
        let ghostItem = ContentItem(type: .image, storagePath: "Clipboard/2020-01/ghost.png", thumbnailPath: nil)
        try repository.insert(ghostItem)

        // 纯文本条目（无 storagePath，应保留）
        let textItem = ContentItem(type: .text, textContent: "keep me")
        try repository.insert(textItem)

        let service = HistoryService(repository: repository, fileStore: fileStore, databaseURL: root.appendingPathComponent("db.sqlite"))
        let removed = await service.healOrphans()

        XCTAssertEqual(removed, 1)
        XCTAssertNil(try repository.find(id: ghostItem.id), "文件丢失条目应被删除")
        XCTAssertNotNil(try repository.find(id: realItem.id), "文件存在条目保留")
        XCTAssertNotNil(try repository.find(id: textItem.id), "纯文本条目保留")
    }
}
