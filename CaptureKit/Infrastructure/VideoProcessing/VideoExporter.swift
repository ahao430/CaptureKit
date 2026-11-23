import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// 录制导出（plan.md §2.6.6 P0：mp4 裁剪导出 + GIF 转换）。
enum VideoExporter {
    enum ExportError: Error {
        case noVideoTrack
        case cannotCreateSession
        case exportFailed(String?)
        case gifEncodeFailed
    }

    // MARK: - mp4 导出

    /// mp4 裁剪导出。
    /// - Parameters:
    ///   - preset: `AVAssetExportPreset*`；`AVAssetExportPresetPassthrough` 保持原始质量（仅裁剪，不重编码）。
    ///   - speed: 播放速度（1.0 正常；≠1 时走 AVMutableComposition 重定时，passthrough 失效自动降级 720p 编码）。
    static func exportMP4(from source: URL,
                          to destination: URL,
                          timeRange: CMTimeRange,
                          preset: String = AVAssetExportPresetPassthrough,
                          speed: Double = 1.0) async throws -> URL {
        let asset = AVURLAsset(url: source)

        if abs(speed - 1.0) > 0.01 {
            return try await exportMP4WithSpeed(asset: asset, destination: destination, timeRange: timeRange, speed: speed)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.cannotCreateSession
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        session.timeRange = timeRange
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        if session.status == .completed {
            Log.export.info("mp4 exported: \(destination.lastPathComponent, privacy: .public) [\(preset, privacy: .public)]")
            return destination
        }
        throw ExportError.exportFailed(session.error?.localizedDescription)
    }

    /// 变速导出：composition 插入裁剪区间 → scaleTimeRange 重定时 → 重编码导出。
    private static func exportMP4WithSpeed(asset: AVURLAsset,
                                            destination: URL,
                                            timeRange: CMTimeRange,
                                            speed: Double) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ExportError.noVideoTrack
        }
        try compositionVideo.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        let scaledDuration = CMTimeMultiplyByFloat64(timeRange.duration, multiplier: 1.0 / max(0.25, speed))
        compositionVideo.scaleTimeRange(timeRange, toDuration: scaledDuration)

        // 音频轨同速重定时（存在时）
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudio.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            compositionAudio.scaleTimeRange(timeRange, toDuration: scaledDuration)
        }

        // 变速必须重编码；passthrough 不可用 → 最高质量
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.cannotCreateSession
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4

        await session.export()
        if session.status == .completed {
            Log.export.info("mp4 exported with speed \(speed): \(destination.lastPathComponent, privacy: .public)")
            return destination
        }
        throw ExportError.exportFailed(session.error?.localizedDescription)
    }

    // MARK: - GIF 转换

    /// mp4 → GIF：AVAssetReader 按裁剪区间与目标帧率读帧（自动缩放与方向修正）→ GIFEncoder 流式写入。
    /// - Parameters:
    ///   - speed: 播放速度（帧延迟 = 1/(fps×speed)）。
    ///   - exclusions: 删帧区间（源绝对时间轴；命中的帧跳过，Phase 6 删帧编辑）。
    static func exportGIF(from source: URL,
                          to destination: URL,
                          timeRange: CMTimeRange,
                          fps: Int,
                          maxPixelWidth: Int,
                          speed: Double = 1.0,
                          exclusions: FrameExclusions = FrameExclusions(),
                          progress: ((Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        // 目标尺寸（等比缩放；截屏录制无旋转，用 TrackOutput 像素缩放即可，
        // 避免 AVMutableVideoComposition(propertiesOf:) 同步初始化的偶发 -11841 竞态）
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientedSize = CGSize(
            width: abs(naturalSize.width * transform.a) + abs(naturalSize.height * transform.b),
            height: abs(naturalSize.width * transform.c) + abs(naturalSize.height * transform.d)
        )
        let scale = min(1, CGFloat(maxPixelWidth) / max(1, orientedSize.width))
        let targetSize = CGSize(
            width: max(2, orientedSize.width * scale),
            height: max(2, orientedSize.height * scale)
        )

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(targetSize.width),
            kCVPixelBufferHeightKey as String: Int(targetSize.height),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw ExportError.exportFailed(reader.error?.localizedDescription)
        }

        try? FileManager.default.removeItem(at: destination)
        let encoder = try GIFEncoder(outputURL: destination, fps: fps, maxPixelWidth: maxPixelWidth, playbackSpeed: speed)

        // 读取循环放在后台（copyNextSampleBuffer 是同步 API）
        let rangeDuration = max(0.01, CMTimeGetSeconds(timeRange.duration))
        var lastPTS: Double?

        try await Task.detached(priority: .userInitiated) {
            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                // 删帧：命中排除段直接跳过
                if exclusions.isExcluded(pts) {
                    continue
                }
                // 目标帧率节流
                if let last = lastPTS, pts - last < 1.0 / Double(max(5, fps)) * 0.9 {
                    continue
                }
                lastPTS = pts
                guard let buffer = CMSampleBufferGetImageBuffer(sample),
                      let image = PixelBufferCropper.cgImage(from: buffer)
                else { continue }
                try encoder.append(image)
                let normalized = min(1, pts / rangeDuration)
                await MainActor.run { progress?(normalized) }
            }
        }.value

        if reader.status == .failed {
            encoder.cancel()
            throw ExportError.exportFailed(reader.error?.localizedDescription)
        }
        do {
            try encoder.finish()
        } catch {
            throw ExportError.gifEncodeFailed
        }
        Log.export.info("GIF exported: \(destination.lastPathComponent, privacy: .public) (\(encoder.appendedFrameCount) frames)")
        return destination
    }
}
