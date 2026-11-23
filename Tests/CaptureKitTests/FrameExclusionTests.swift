import AVFoundation
import CoreMedia
import XCTest

@testable import CaptureKit

/// 删帧区间模型（Phase 6 删帧编辑）。
final class FrameExclusionTests: XCTestCase {
    func testMergeOverlapping() {
        let merged = FrameExclusions.merged([
            ExcludedRange(start: 0, end: 1),
            ExcludedRange(start: 0.5, end: 2),
        ])
        XCTAssertEqual(merged, [ExcludedRange(start: 0, end: 2)])
    }

    func testMergeAdjacent() {
        let merged = FrameExclusions.merged([
            ExcludedRange(start: 0, end: 1),
            ExcludedRange(start: 1, end: 2),
        ])
        XCTAssertEqual(merged, [ExcludedRange(start: 0, end: 2)])
    }

    func testKeepsGap() {
        let merged = FrameExclusions.merged([
            ExcludedRange(start: 0, end: 1),
            ExcludedRange(start: 2, end: 3),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testFiltersZeroAndReorders() {
        let merged = FrameExclusions.merged([
            ExcludedRange(start: 5, end: 6),
            ExcludedRange(start: 1, end: 1), // 零长
            ExcludedRange(start: 0, end: 0.5),
        ])
        XCTAssertEqual(merged, [
            ExcludedRange(start: 0, end: 0.5),
            ExcludedRange(start: 5, end: 6),
        ])
    }

    func testIsExcludedHalfOpen() {
        let exclusions = FrameExclusions(ranges: [ExcludedRange(start: 1, end: 2)])
        XCTAssertFalse(exclusions.isExcluded(0.999))
        XCTAssertTrue(exclusions.isExcluded(1.0))
        XCTAssertTrue(exclusions.isExcluded(1.5))
        XCTAssertFalse(exclusions.isExcluded(2.0)) // 右开区间
    }

    func testToggleAddThenRemove() {
        var exclusions = FrameExclusions()
        XCTAssertTrue(exclusions.isEmpty)

        exclusions.toggle(ExcludedRange(start: 1, end: 2))
        XCTAssertEqual(exclusions.ranges, [ExcludedRange(start: 1, end: 2)])
        XCTAssertEqual(exclusions.totalExcludedDuration, 1.0, accuracy: 0.001)

        // 中点命中 → 移除
        exclusions.toggle(ExcludedRange(start: 1.4, end: 1.6))
        XCTAssertTrue(exclusions.isEmpty)
    }

    func testToggleMergeOnAdd() {
        var exclusions = FrameExclusions(ranges: [ExcludedRange(start: 0, end: 1)])
        exclusions.toggle(ExcludedRange(start: 0.5, end: 2)) // 中点 1.25 未命中 → 加入合并
        XCTAssertEqual(exclusions.ranges, [ExcludedRange(start: 0, end: 2)])
    }

    func testClipped() {
        let exclusions = FrameExclusions(ranges: [
            ExcludedRange(start: 0, end: 1),
            ExcludedRange(start: 1.5, end: 3),
            ExcludedRange(start: 5, end: 6), // 全在窗口外
        ])
        let clipped = exclusions.clipped(lower: 0.5, upper: 2)
        XCTAssertEqual(clipped.ranges, [
            ExcludedRange(start: 0.5, end: 1),
            ExcludedRange(start: 1.5, end: 2),
        ])
        XCTAssertEqual(clipped.totalExcludedDuration, 1.0, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let exclusions = FrameExclusions(ranges: [ExcludedRange(start: 0.5, end: 1.5)])
        let data = try JSONEncoder().encode(exclusions)
        let decoded = try JSONDecoder().decode(FrameExclusions.self, from: data)
        XCTAssertEqual(decoded, exclusions)
    }

    /// 导出集成：中间 0.4s 被排除 → GIF 帧数按比例减少。
    func testExportGIFSkipsExcludedRanges() async throws {
        let source = try await ExportSpeedTests.makeTempVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("cut.gif")

        let exclusions = FrameExclusions(ranges: [ExcludedRange(start: 0.3, end: 0.7)])
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600))
        let url = try await VideoExporter.exportGIF(
            from: source, to: destination, timeRange: range,
            fps: 10, maxPixelWidth: 240, exclusions: exclusions
        )

        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        XCTAssertNotNil(imageSource)
        let count = CGImageSourceGetCount(imageSource!)
        // 1s @10fps ≈ 10 帧；排除 0.4s → 约 6 帧（节流容差放宽）
        XCTAssertGreaterThanOrEqual(count, 4)
        XCTAssertLessThanOrEqual(count, 8)
    }
}
