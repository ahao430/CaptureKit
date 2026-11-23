import AppKit
import CoreGraphics
import XCTest

@testable import CaptureKit

/// 异步缩略图缓存（plan.md §11 性能：历史列表按需加载，主线程不解码）。
@MainActor
final class ThumbnailStoreTests: XCTestCase {
    private var root: URL!
    private var fileStore: ContentFileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitThumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileStore = ContentFileStore(rootURL: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makePNG() throws -> Data {
        let image = CGImage.testImage(width: 60, height: 40, color: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        return ClipboardWriter.pngData(from: image)!
    }

    func testDecodesAndCaches() async throws {
        let store = ThumbnailStore(fileStore: fileStore)
        let path = try fileStore.save(data: makePNG(), kind: .clipboard, fileExtension: "png")
        let item = ContentItem(type: .image, thumbnailPath: path)

        let first = await store.image(for: item)
        XCTAssertNotNil(first)

        // 命中缓存：同一实例
        let second = await store.image(for: item)
        XCTAssertTrue(first === second)
    }

    func testMissingFileReturnsNil() async throws {
        let store = ThumbnailStore(fileStore: fileStore)
        let item = ContentItem(type: .image, thumbnailPath: "Clipboard/2020-01/ghost.png")
        let image = await store.image(for: item)
        XCTAssertNil(image)
    }

    func testNilThumbnailPathReturnsNil() async throws {
        let store = ThumbnailStore(fileStore: fileStore)
        let item = ContentItem(type: .text, textContent: "no file")
        let image = await store.image(for: item)
        XCTAssertNil(image)
    }

    func testCorruptDataReturnsNil() async throws {
        let store = ThumbnailStore(fileStore: fileStore)
        let path = try fileStore.save(data: Data("not an image".utf8), kind: .clipboard, fileExtension: "png")
        let item = ContentItem(type: .image, thumbnailPath: path)
        let image = await store.image(for: item)
        XCTAssertNil(image)
    }
}
