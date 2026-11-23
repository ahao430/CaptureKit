import AVFoundation
import XCTest

@testable import CaptureKit

/// 录屏入库回归（用户报告：录制后历史无条目）。
/// 复现 recordRecording 全链路：真实 mp4 → 去重 → 落盘 → 缩略图 → 入库。
@MainActor
final class RecordingHistoryTests: XCTestCase {
    func testRecordedVideoAppearsInHistory() async throws {
        let repository = try ContentRepository.temporary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitRecHist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = ContentFileStore(rootURL: root)
        let service = HistoryService(repository: repository, fileStore: fileStore, databaseURL: root.appendingPathComponent("db.sqlite"))

        // 真实可播放的视频（复用导出测试的造数管线）
        let video = try await ExportSpeedTests.makeTempVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        precondition(FileManager.default.fileExists(atPath: video.path), "源视频必须存在")

        await service.recordRecording(url: video, mode: .video, duration: 1.0, fps: 30)

        // 断言：历史中出现 video 条目，且文件已复制进 Content
        let count = await service.itemCount()
        XCTAssertEqual(count, 1, "录制产物必须入库（用户报告：录屏后历史无条目）")

        let items = try repository.fetch(query: .init())
        guard let item = items.first else {
            XCTFail("无条目")
            return
        }
        XCTAssertEqual(item.type, .video)
        XCTAssertNotNil(item.storagePath)
        if let storagePath = item.storagePath {
            // storagePath 是相对 rootURL 的相对路径（便于迁移），UI 侧经 url(forRelativePath:) 解析
            let absolute = fileStore.url(forRelativePath: storagePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path), "内容文件应已落盘：\(absolute.path)")
        }
    }

    func testRecordedVideoDeduplicates() async throws {
        let repository = try ContentRepository.temporary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitRecHist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = HistoryService(repository: repository, fileStore: ContentFileStore(rootURL: root), databaseURL: root.appendingPathComponent("db.sqlite"))

        let video = try await ExportSpeedTests.makeTempVideo(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }

        await service.recordRecording(url: video, mode: .video, duration: 1.0, fps: 30)
        await service.recordRecording(url: video, mode: .video, duration: 1.0, fps: 30)

        let count = await service.itemCount()
        XCTAssertEqual(count, 1, "同一视频重复入库应去重 bump")
    }
}
