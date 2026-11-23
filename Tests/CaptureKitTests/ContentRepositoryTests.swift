import CoreGraphics
import Foundation
import XCTest

@testable import CaptureKit

/// SQLite 封装与内容仓库（design.md §10）。
final class ContentRepositoryTests: XCTestCase {
    private var repository: ContentRepository!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        // 每个用例独立的临时数据库文件（WAL 等真实文件行为）
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitDB-\(UUID().uuidString).sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        repository = try ContentRepository(database: database)
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        super.tearDown()
    }

    private func makeItem(type: ContentType = .text,
                          text: String? = "hello",
                          createdAt: Date = Date(),
                          pinned: Bool = false,
                          hash: String? = nil) -> ContentItem {
        ContentItem(
            type: type,
            createdAt: createdAt,
            textContent: text,
            metadata: .clipboard(.init(sourceBundleID: "com.apple.Safari", representations: ["string"])),
            isPinned: pinned,
            contentHash: hash
        )
    }

    // MARK: - CRUD

    func testInsertAndFind() throws {
        let item = makeItem()
        try repository.insert(item)

        let found = try repository.find(id: item.id)
        XCTAssertEqual(found?.id, item.id)
        XCTAssertEqual(found?.type, .text)
        XCTAssertEqual(found?.textContent, "hello")
        XCTAssertEqual(found?.isPinned, false)

        // 元数据 typed 往返
        if case .clipboard(let meta)? = found?.metadata {
            XCTAssertEqual(meta.sourceBundleID, "com.apple.Safari")
            XCTAssertEqual(meta.representations, ["string"])
        } else {
            XCTFail("metadata should be clipboard")
        }
    }

    func testDeleteRemovesRow() throws {
        let item = makeItem()
        try repository.insert(item)

        let deleted = try repository.delete(id: item.id)
        XCTAssertEqual(deleted?.id, item.id)
        XCTAssertNil(try repository.find(id: item.id))
        // 再删返回 nil
        XCTAssertNil(try repository.delete(id: item.id))
    }

    func testSetPinnedAndTouch() throws {
        let item = makeItem()
        try repository.insert(item)

        try repository.setPinned(id: item.id, pinned: true)
        XCTAssertTrue(try repository.find(id: item.id)!.isPinned)

        let before = try repository.find(id: item.id)!.updatedAt
        Thread.sleep(forTimeInterval: 0.02)
        try repository.touch(id: item.id)
        let after = try repository.find(id: item.id)!.updatedAt
        XCTAssertGreaterThan(after, before)
    }

    func testFindByHash() throws {
        let hash = ContentHasher.hash(text: "duplicate me")
        try repository.insert(makeItem(text: "duplicate me", hash: hash))

        let found = try repository.findByHash(hash)
        XCTAssertNotNil(found)
        XCTAssertNil(try repository.findByHash(ContentHasher.hash(text: "other")))
    }

    // MARK: - 查询

    func testFetchOrdersByCreatedAtDescending() throws {
        let old = makeItem(text: "old", createdAt: Date(timeIntervalSinceNow: -100))
        let new = makeItem(text: "new", createdAt: Date())
        try repository.insert(old)
        try repository.insert(new)

        let items = try repository.fetch(query: ContentQuery())
        XCTAssertEqual(items.map(\.textContent), ["new", "old"])
    }

    func testFetchCategoryFilters() throws {
        try repository.insert(makeItem(type: .text, text: "clip"))                       // 剪贴板来源
        try repository.insert(makeItem(type: .screenshot, text: "shot"))                 // 类型截图
        let items = try repository.fetch(query: ContentQuery(category: .clipboard))
        // clipboard 分类 = metadata 为 clipboard 的（含上面两条，因为 makeItem 默认 clipboard metadata）
        XCTAssertEqual(items.count, 2)

        // screenshot 分类 = 类型截图
        let shots = try repository.fetch(query: ContentQuery(category: .screenshot))
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots.first?.type, .screenshot)

        // recording 分类
        try repository.insert(makeItem(type: .video, text: nil))
        let recordings = try repository.fetch(query: ContentQuery(category: .recording))
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings.first?.type, .video)
    }

    func testFetchPinnedCategory() throws {
        try repository.insert(makeItem(text: "pinned", pinned: true))
        try repository.insert(makeItem(text: "normal"))
        let pinned = try repository.fetch(query: ContentQuery(category: .pinned))
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.isPinned, true)
    }

    func testFetchSearchText() throws {
        try repository.insert(makeItem(text: "Swift 并发指南"))
        try repository.insert(makeItem(text: "Rust 入门"))
        let result = try repository.fetch(query: ContentQuery(searchText: "Swift"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.textContent, "Swift 并发指南")
        // 大小写不敏感（SQLite LIKE 默认 ASCII 不敏感）
        XCTAssertEqual(try repository.fetch(query: ContentQuery(searchText: "swift")).count, 1)
    }

    // MARK: - 清理

    func testPurgeOldItemsExcludesPinned() throws {
        let oldDate = Date(timeIntervalSinceNow: -86_400 * 40)
        try repository.insert(makeItem(text: "old-pinned", createdAt: oldDate, pinned: true))
        try repository.insert(makeItem(text: "old-normal", createdAt: oldDate))
        try repository.insert(makeItem(text: "fresh"))

        let removed = try repository.purge(olderThan: Date(timeIntervalSinceNow: -86_400 * 30))
        XCTAssertEqual(removed.map(\.textContent), ["old-normal"])
        XCTAssertEqual(try repository.count(), 2) // pinned 旧项 + 新项
    }

    func testEnforceLimitKeepsPinned() throws {
        // 5 条旧未固定 + 1 条旧固定 + 3 条新未固定，keep 4：
        for index in 0..<5 {
            try repository.insert(makeItem(text: "old\(index)", createdAt: Date(timeIntervalSinceNow: -1000 + Double(index))))
        }
        try repository.insert(makeItem(text: "pinned-old", createdAt: Date(timeIntervalSinceNow: -2000), pinned: true))
        for index in 0..<3 {
            try repository.insert(makeItem(text: "new\(index)", createdAt: Date(timeIntervalSinceNow: -10 + Double(index))))
        }

        let removed = try repository.enforceLimit(keepCount: 4)
        // 总 9 条，pin 不算配额：未固定 8 条 → 保留 4 → 删 4 条最旧
        XCTAssertEqual(removed.count, 4)
        XCTAssertEqual(try repository.count(), 5) // 4 未固定 + 1 固定
        let remainingTexts = Set(try repository.fetch(query: ContentQuery()).map { $0.textContent ?? "" })
        XCTAssertTrue(remainingTexts.contains("pinned-old"))
    }

    func testDeleteAllReturnsEverything() throws {
        try repository.insert(makeItem(text: "a"))
        try repository.insert(makeItem(text: "b"))
        let removed = try repository.deleteAll()
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(try repository.count(), 0)
    }

    // MARK: - 迁移

    func testMigrationIsIdempotent() throws {
        // 重新打开同一数据库：user_version 已是 1，迁移跳过不报错
        let database = try SQLiteDatabase(url: databaseURL)
        let repository2 = try ContentRepository(database: database)
        XCTAssertEqual(try repository2.count(), 0)
    }

    // MARK: - 哈希

    func testTextHashNormalizesWhitespaceOnly() {
        let a = ContentHasher.hash(text: "  hello world  \n")
        let b = ContentHasher.hash(text: "hello world")
        XCTAssertEqual(a, b)
        // 大小写保留（刻意差异）
        XCTAssertNotEqual(a, ContentHasher.hash(text: "Hello World"))
    }

    func testBinaryHashDistinct() {
        XCTAssertEqual(ContentHasher.hash(data: Data([1, 2, 3])), ContentHasher.hash(data: Data([1, 2, 3])))
        XCTAssertNotEqual(ContentHasher.hash(data: Data([1, 2, 3])), ContentHasher.hash(data: Data([1, 2, 4])))
    }
}

/// 剪贴板分类与敏感过滤。
final class ClipboardProcessingTests: XCTestCase {
    // MARK: - 分类

    private func reading(text: String? = nil, imageData: Data? = nil,
                         fileURLs: [URL] = [], representations: [String] = ["string"]) -> ClipboardReading {
        ClipboardReading(
            text: text,
            imageData: imageData,
            imageIsPNG: imageData != nil,
            fileURLs: fileURLs,
            sourceBundleID: nil,
            representations: representations
        )
    }

    func testClassifyFileWins() {
        let result = ClipboardClassifier.classify(reading(
            text: "/Users/a/file.txt",
            fileURLs: [URL(fileURLWithPath: "/Users/a/file.txt")],
            representations: ["fileURL", "string"]
        ))
        if case .file(let paths) = result {
            XCTAssertEqual(paths, ["/Users/a/file.txt"])
        } else {
            XCTFail("expected file, got \(result)")
        }
    }

    func testClassifyImage() {
        let result = ClipboardClassifier.classify(reading(text: nil, imageData: Data([1]), representations: ["image"]))
        XCTAssertEqual(result.contentType, .image)
    }

    func testClassifyURL() {
        let result = ClipboardClassifier.classify(reading(text: "https://example.com/page?q=1"))
        if case .url(let url) = result {
            XCTAssertEqual(url.host, "example.com")
        } else {
            XCTFail("expected url, got \(result)")
        }
        // 多行文本不是 URL
        let multi = ClipboardClassifier.classify(reading(text: "https://example.com\nsecond line"))
        XCTAssertEqual(multi.contentType, .text)
    }

    func testClassifyRichText() {
        let result = ClipboardClassifier.classify(reading(text: "styled", representations: ["string", "rtf"]))
        XCTAssertEqual(result, .richText)
    }

    // MARK: - 敏感检测

    func testDetectsAWSCredentials() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("AKIAIOSFODNN7EXAMPLE"))
    }

    func testDetectsGitHubToken() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("ghp_16C7e42F292c6912E7710c838347Ae178B4a"))
    }

    func testDetectsOpenAIStyleKey() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("sk-proj-abcdefghijklmnopqrstuvwxyz123456"))
    }

    func testDetectsPasswordAssignment() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("password: hunter2secure"))
        XCTAssertTrue(SensitiveContentDetector.isSensitive("API_KEY=abcd1234efgh5678"))
    }

    func testDetectsPrivateKey() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("-----BEGIN RSA PRIVATE KEY-----\nMIIE..."))
    }

    func testDetectsHighEntropySecret() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRva2VuIHZhbHVl"))
    }

    func testAllowsNormalText() {
        XCTAssertFalse(SensitiveContentDetector.isSensitive("Hello world"))
        XCTAssertFalse(SensitiveContentDetector.isSensitive("https://example.com/some/article"))
        XCTAssertFalse(SensitiveContentDetector.isSensitive("会议纪要：明天上午十点，三楼会议室，请准时参加。"))
        XCTAssertFalse(SensitiveContentDetector.isSensitive(""))
    }
}
