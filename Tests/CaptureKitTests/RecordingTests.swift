import AVFoundation
import CoreAudio
import CoreGraphics
import XCTest

@testable import CaptureKit

/// 暂停时间轴（design.md §8.4 帧管线核心逻辑）。
final class PauseTimelineTests: XCTestCase {
    func testNoPausePassesThrough() {
        var timeline = PauseTimeline()
        XCTAssertEqual(timeline.adjustedPTS(12.5), 12.5)
        XCTAssertFalse(timeline.shouldDropFrame(at: 12.5))
        XCTAssertEqual(timeline.totalPausedDuration, 0)
    }

    func testPauseDropsFramesUntilResume() {
        var timeline = PauseTimeline()
        timeline.pause(at: 10.0)
        XCTAssertTrue(timeline.isPaused)
        // 暂停起点之后（含起点）的帧丢弃
        XCTAssertTrue(timeline.shouldDropFrame(at: 10.0))
        XCTAssertTrue(timeline.shouldDropFrame(at: 12.0))
        // 暂停前的帧不丢
        XCTAssertFalse(timeline.shouldDropFrame(at: 9.9))

        timeline.resume(at: 15.0)
        XCTAssertFalse(timeline.isPaused)
        XCTAssertFalse(timeline.shouldDropFrame(at: 15.0))
        XCTAssertEqual(timeline.totalPausedDuration, 5.0, accuracy: 0.001)
    }

    func testAdjustedPTSRemovesEarlierPauseOnly() {
        var timeline = PauseTimeline()
        // 暂停 10→15（5s）、20→23（3s）
        timeline.pause(at: 10.0)
        timeline.resume(at: 15.0)
        timeline.pause(at: 20.0)
        timeline.resume(at: 23.0)

        // 暂停前的帧不受影响
        XCTAssertEqual(timeline.adjustedPTS(8.0), 8.0, accuracy: 0.001)
        // 第一段暂停内的帧（会被丢弃，但公式上只扣除之前段 = 0）
        XCTAssertEqual(timeline.adjustedPTS(12.0), 12.0, accuracy: 0.001)
        // 第一段之后：扣 5s
        XCTAssertEqual(timeline.adjustedPTS(18.0), 13.0, accuracy: 0.001)
        // 两段之后：扣 8s
        XCTAssertEqual(timeline.adjustedPTS(30.0), 22.0, accuracy: 0.001)
    }

    func testDoublePauseIgnored() {
        var timeline = PauseTimeline()
        timeline.pause(at: 10.0)
        timeline.pause(at: 12.0) // 忽略
        XCTAssertEqual(timeline.pauseStartedAt, 10.0)
        timeline.resume(at: 14.0)
        XCTAssertEqual(timeline.totalPausedDuration, 4.0, accuracy: 0.001)
    }

    func testZeroLengthPauseIgnored() {
        var timeline = PauseTimeline()
        timeline.pause(at: 10.0)
        timeline.resume(at: 10.0) // 同刻恢复 → 0 长度段不计
        XCTAssertEqual(timeline.totalPausedDuration, 0.0, accuracy: 0.001)
        XCTAssertEqual(timeline.adjustedPTS(20.0), 20.0, accuracy: 0.001)
    }
}

/// 录制设置与坐标。
final class RecordingSettingsTests: XCTestCase {
    func testSettingsDecodingDefaults() throws {
        // 旧配置缺 recording/clipboard/quickAccess 段 → 默认
        let legacy = #"{"capture":{"delaySeconds":5}}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.recording.fps, 30)
        XCTAssertEqual(decoded.recording.gifMaxPixelWidth, 720)
        XCTAssertTrue(decoded.recording.showsCursor)
        XCTAssertEqual(decoded.hotkeys.recordRegion, HotkeyDescriptor.recordRegion())
        XCTAssertEqual(decoded.hotkeys.quickAccess, HotkeyDescriptor.quickAccess())
        XCTAssertFalse(decoded.clipboard.enabled, "剪贴板历史默认必须关闭")
        XCTAssertFalse(decoded.recording.audioEnabled, "系统音频默认关")
        XCTAssertFalse(decoded.recording.microphoneEnabled, "麦克风默认关")
        XCTAssertFalse(decoded.recording.clickEffects, "点击效果默认关")
        XCTAssertTrue(decoded.recording.autoOpenEditor)
    }

    func testDefaultRecordHotkeyIsCmdShiftR() {
        XCTAssertEqual(HotkeyDescriptor.recordRegion().displayName, "⇧⌘R")
    }

    /// 区域 → 帧像素坐标：y 翻转到左上原点，按实际帧尺寸缩放。
    func testPixelRectConversion() {
        let display = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // 逻辑区域：副屏本地 (100, 200) 起 400×300（y 向上）
        let region = CGRect(x: 1540, y: 200, width: 400, height: 300)
        // Retina 2x 帧 3840×2160
        let pixelRect = PixelBufferCropper.pixelRect(
            forRegion: region,
            displayFrame: display,
            framePixelSize: CGSize(width: 3840, height: 2160)
        )
        // 左上原点：x = 200；y = (1080-500)*2 = 1160；尺寸 800×600
        XCTAssertEqual(pixelRect, CGRect(x: 200, y: 1160, width: 800, height: 600))
    }

    func testHudTimeFormat() {
        XCTAssertEqual(RecordingHUDPanel.format(0), "00:00")
        XCTAssertEqual(RecordingHUDPanel.format(65), "01:05")
        XCTAssertEqual(RecordingHUDPanel.format(3671), "01:01:11")
    }
}

/// 编码器烟测：合成帧写入 → 文件可解码。
final class RecordingEncoderTests: XCTestCase {
    private func makeFrame(width: Int, height: Int, seed: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: CGFloat(seed % 5) / 4, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testGIFEncoderProducesPlayableFile() throws {
        let directory = tempDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.gif")

        let encoder = try GIFEncoder(outputURL: url, fps: 10, maxPixelWidth: 480)
        // 宽 800 帧（触发缩放）+ 原始小帧
        try encoder.append(makeFrame(width: 800, height: 600, seed: 1))
        try encoder.append(makeFrame(width: 800, height: 600, seed: 2))
        try encoder.append(makeFrame(width: 800, height: 600, seed: 3))
        try encoder.finish()

        // 文件存在且 ImageIO 可读出帧数与尺寸
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 100)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertEqual(CGImageSourceGetCount(source!), 3)
        let frame = CGImageSourceCreateImageAtIndex(source!, 0, nil)
        XCTAssertEqual(frame?.width, 480)
        // GIF 帧延迟
        let delay = CGImageSourceCopyPropertiesAtIndex(source!, 0, nil) as? [String: Any]
        let gifDict = delay?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let frameDelay = gifDict?[kCGImagePropertyGIFDelayTime as String] as? Double
        XCTAssertEqual(frameDelay ?? 0, 0.1, accuracy: 0.01)
    }

    func testGIFScaleKeepsSmallFrameUntouched() {
        let image = makeFrame(width: 200, height: 100, seed: 0)
        let scaled = GIFEncoder.scaled(image: image, maxPixelWidth: 480)
        XCTAssertEqual(scaled.width, 200)
        XCTAssertEqual(scaled.height, 100)
    }

    func testVideoWriterProducesPlayableMP4() async throws {
        let directory = tempDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.mp4")

        let writer = try VideoWriter(
            outputURL: url,
            size: CGSize(width: 320, height: 240),
            audioFormatDescription: VideoWriter.makeDefaultAudioFormatDescription()
        )
        writer.start()

        // 生成 30 帧合成 CMSampleBuffer（10fps × 3s）
        var frames = 0
        for index in 0..<30 {
            let pixelBuffer = try Self.makePixelBuffer(width: 320, height: 240, seed: index)
            guard let buffer = RecordingEncoderTests.makeSampleBuffer(from: pixelBuffer, seconds: Double(index) / 10.0) else {
                XCTFail("cannot make sample buffer")
                return
            }
            if writer.append(buffer, outputPTS: CMTime(seconds: Double(index) / 10.0, preferredTimescale: 600)) {
                frames += 1
            }
        }
        // 追加静音音频轨（验证 init 附加 + appendAudio）
        var audioAppended = 0
        if let audioFormat = VideoWriter.makeDefaultAudioFormatDescription() {
            for index in 0..<40 {
                guard let audioBuffer = makeSilenceAudioBuffer(at: Double(index) * 1024.0 / 48_000.0, format: audioFormat) else { continue }
                if writer.appendAudio(audioBuffer, outputPTS: CMTime(seconds: Double(index) * 1024.0 / 48_000.0, preferredTimescale: 48_000)) {
                    audioAppended += 1
                }
            }
        }
        XCTAssertGreaterThan(audioAppended, 0, "音频帧应可写入")
        XCTAssertGreaterThan(frames, 0)
        let finalURL = try await writer.finish()

        // AVAsset 可读、时长 ≈ 3s、有视频轨 + 音频轨
        let asset = AVURLAsset(url: finalURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.9, accuracy: 0.5)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    /// 生成静音 CMSampleBuffer（按给定格式，1024 samples/块）。
    private func makeSilenceAudioBuffer(at seconds: Double, format: CMFormatDescription) -> CMSampleBuffer? {
        let frameCount = 1024
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        let dataSize = Int(asbd.mBytesPerFrame) * frameCount
        let sampleRate = asbd.mSampleRate

        var blockBuffer: CMBlockBuffer?
        let silence = Data(count: dataSize)
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let block = blockBuffer,
              silence.withUnsafeBytes({ raw in
                  guard let base = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
                  return CMBlockBufferReplaceDataBytes(
                      with: base,
                      blockBuffer: block,
                      offsetIntoDestination: 0,
                      dataLength: dataSize
                  )
              }) == kCMBlockBufferNoErr
        else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    // MARK: - 合成帧工具

    /// 生成一个临时 mp4（供导出测试）。
    private func makeTempVideo(seconds: Double = 2.0) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.mp4")

        let writer = try VideoWriter(outputURL: url, size: CGSize(width: 320, height: 240))
        writer.start()
        let frames = Int(seconds * 10)
        for index in 0..<frames {
            let buffer = try Self.makePixelBuffer(width: 320, height: 240, seed: index)
            if let sample = RecordingEncoderTests.makeSampleBuffer(from: buffer, seconds: Double(index) / 10.0) {
                writer.append(sample, outputPTS: CMTime(seconds: Double(index) / 10.0, preferredTimescale: 600))
            }
        }
        _ = try await writer.finish()
        return url
    }

    func testExportMP4Trim() async throws {
        let source = try await makeTempVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("trimmed.mp4")

        let range = CMTimeRange(
            start: CMTime(seconds: 0.5, preferredTimescale: 600),
            duration: CMTime(seconds: 1.0, preferredTimescale: 600)
        )
        let url = try await VideoExporter.exportMP4(from: source, to: destination, timeRange: range)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        // passthrough 裁剪时长 ≈ 1s（允许关键帧对齐误差）
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.4)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testExportGIFFromVideo() async throws {
        let source = try await makeTempVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("out.gif")

        let range = CMTimeRange(
            start: CMTime(seconds: 0.2, preferredTimescale: 600),
            duration: CMTime(seconds: 1.4, preferredTimescale: 600)
        )
        let url = try await VideoExporter.exportGIF(from: source, to: destination, timeRange: range, fps: 10, maxPixelWidth: 240)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 200)
        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        XCTAssertNotNil(imageSource)
        // 1.4s @ 10fps ≈ 14 帧（节流容差）
        let count = CGImageSourceGetCount(imageSource!)
        XCTAssertGreaterThanOrEqual(count, 8)
        XCTAssertLessThanOrEqual(count, 20)
        // 尺寸缩放到 ≤ 240 宽
        let frame = CGImageSourceCreateImageAtIndex(imageSource!, 0, nil)
        XCTAssertLessThanOrEqual(frame?.width ?? 0, 240)
    }

    static func makePixelBuffer(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { throw XCTSkip("cannot create pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: CGFloat(seed % 3) / 3, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, seconds: Double) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return nil }
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}
