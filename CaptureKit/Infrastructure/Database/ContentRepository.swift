import CryptoKit
import Foundation

/// 内容仓库（design.md §10.4）：SQLite 持久化 + 条件查询 + 去重 + 清理。
/// 所有方法在数据库串行队列上执行（经 async 包装）。
final class ContentRepository {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) throws {
        self.database = database
        try Self.migrate(database)
    }

    /// 临时文件数据库（测试用；调用方负责清理文件）。
    /// 不用 ":memory:"：URL.path 处理会破坏 sqlite 的内存库标记字符串。
    static func temporary() throws -> ContentRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitRepo-\(UUID().uuidString).sqlite")
        return try ContentRepository(database: SQLiteDatabase(url: url))
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.migrate(migrations: [
            (
                1,
                """
                CREATE TABLE IF NOT EXISTS contents (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    storage_path TEXT,
                    thumbnail_path TEXT,
                    text_content TEXT,
                    metadata_json TEXT,
                    is_pinned INTEGER NOT NULL DEFAULT 0,
                    content_hash TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_contents_created ON contents(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_contents_type ON contents(type);
                CREATE INDEX IF NOT EXISTS idx_contents_hash ON contents(content_hash);
                """
            ),
        ])
    }

    // MARK: - 写入

    func insert(_ item: ContentItem) throws {
        let metadataData = try JSONEncoder().encode(item.metadata)
        try database.run(
            """
            INSERT INTO contents (id, type, created_at, updated_at, storage_path, thumbnail_path, text_content, metadata_json, is_pinned, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(item.id.uuidString),
                .text(item.type.rawValue),
                .double(item.createdAt.timeIntervalSince1970),
                .double(item.updatedAt.timeIntervalSince1970),
                item.storagePath.map { .text($0) } ?? .null,
                item.thumbnailPath.map { .text($0) } ?? .null,
                item.textContent.map { .text($0) } ?? .null,
                .text(String(data: metadataData, encoding: .utf8) ?? "{}"),
                .int(item.isPinned ? 1 : 0),
                item.contentHash.map { .text($0) } ?? .null,
            ]
        )
    }

    func insertAsync(_ item: ContentItem) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try insert(item)
        }.value
    }

    func update(_ item: ContentItem) throws {
        let metadataData = try JSONEncoder().encode(item.metadata)
        try database.run(
            """
            UPDATE contents SET type = ?, updated_at = ?, storage_path = ?, thumbnail_path = ?, text_content = ?, metadata_json = ?, is_pinned = ?, content_hash = ?
            WHERE id = ?
            """,
            [
                .text(item.type.rawValue),
                .double(item.updatedAt.timeIntervalSince1970),
                item.storagePath.map { .text($0) } ?? .null,
                item.thumbnailPath.map { .text($0) } ?? .null,
                item.textContent.map { .text($0) } ?? .null,
                .text(String(data: metadataData, encoding: .utf8) ?? "{}"),
                .int(item.isPinned ? 1 : 0),
                item.contentHash.map { .text($0) } ?? .null,
                .text(item.id.uuidString),
            ]
        )
    }

    func updateAsync(_ item: ContentItem) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try update(item)
        }.value
    }

    /// 删除并返回被删除条目（供调用方清理关联文件）。
    @discardableResult
    func delete(id: UUID) throws -> ContentItem? {
        guard let item = try find(id: id) else { return nil }
        try database.run("DELETE FROM contents WHERE id = ?", [.text(id.uuidString)])
        return item
    }

    func deleteAsync(id: UUID) async -> ContentItem? {
        await Task.detached(priority: .utility) { [self] in
            try? delete(id: id) ?? nil
        }.value
    }

    func setPinned(id: UUID, pinned: Bool) throws {
        try database.run(
            "UPDATE contents SET is_pinned = ?, updated_at = ? WHERE id = ?",
            [.int(pinned ? 1 : 0), .double(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// 重复内容：bump 更新时间（plan.md §2.7.3：不删除历史，更新最近使用）。
    /// 保证严格大于当前值（同毫秒内重复复制也能推进排序）。
    func touch(id: UUID) throws {
        guard let existing = try find(id: id) else { return }
        let next = max(Date().timeIntervalSince1970, existing.updatedAt.timeIntervalSince1970 + 0.001)
        try database.run(
            "UPDATE contents SET updated_at = ? WHERE id = ?",
            [.double(next), .text(id.uuidString)]
        )
    }

    func touchAsync(id: UUID) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try touch(id: id)
        }.value
    }

    func setPinnedAsync(id: UUID, pinned: Bool) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try setPinned(id: id, pinned: pinned)
        }.value
    }

    func purgeAsync(olderThan cutoff: Date) async throws -> [ContentItem] {
        try await Task.detached(priority: .utility) { [self] in
            try purge(olderThan: cutoff)
        }.value
    }

    func enforceLimitAsync(keepCount: Int) async throws -> [ContentItem] {
        try await Task.detached(priority: .utility) { [self] in
            try enforceLimit(keepCount: keepCount)
        }.value
    }

    func deleteAllAsync() async throws -> [ContentItem] {
        try await Task.detached(priority: .utility) { [self] in
            try deleteAll()
        }.value
    }

    // MARK: - 查询

    func find(id: UUID) throws -> ContentItem? {
        try database.query("SELECT * FROM contents WHERE id = ?", [.text(id.uuidString)], map: Self.mapRow).first
    }

    func findByHash(_ hash: String) throws -> ContentItem? {
        try database.query("SELECT * FROM contents WHERE content_hash = ? LIMIT 1", [.text(hash)], map: Self.mapRow).first
    }

    func findByHashAsync(_ hash: String) async throws -> ContentItem? {
        try await Task.detached(priority: .utility) { [self] in
            try findByHash(hash)
        }.value
    }

    /// 分类 + 搜索查询。
    ///
    /// 分类语义：
    /// - clipboard：剪贴板来源（metadata 为 clipboard）的条目
    /// - screenshot：screenshot / scrollingScreenshot 类型
    /// - recording：video / gif 类型
    /// - pinned：isPinned
    func fetch(query: ContentQuery) throws -> [ContentItem] {
        var sql = "SELECT * FROM contents"
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []

        switch query.category {
        case .all:
            break
        case .clipboard:
            conditions.append("metadata_json LIKE '%\"clipboard\"%'")
        case .screenshot:
            conditions.append("type IN ('screenshot', 'scrollingScreenshot')")
        case .recording:
            conditions.append("type IN ('video', 'gif')")
        case .pinned:
            conditions.append("is_pinned = 1")
        }

        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            conditions.append("text_content LIKE ?")
            bindings.append(.text("%\(search)%"))
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        bindings.append(.int(query.limit))
        bindings.append(.int(query.offset))

        return try database.query(sql, bindings, map: Self.mapRow)
    }

    func fetchAsync(query: ContentQuery) async throws -> [ContentItem] {
        try await Task.detached(priority: .utility) { [self] in
            try fetch(query: query)
        }.value
    }

    func count() throws -> Int {
        try database.query("SELECT COUNT(*) FROM contents", map: { $0.int(0) }).first ?? 0
    }

    func countAsync() async throws -> Int {
        try await Task.detached(priority: .utility) { [self] in
            try count()
        }.value
    }

    /// 清理：删除早于 cutoff 且未固定的条目，返回删除列表（供文件清理）。
    func purge(olderThan cutoff: Date, excludePinned: Bool = true) throws -> [ContentItem] {
        var sql = "SELECT * FROM contents WHERE created_at < ?"
        if excludePinned {
            sql += " AND is_pinned = 0"
        }
        let victims = try database.query(sql, [.double(cutoff.timeIntervalSince1970)], map: Self.mapRow)
        for item in victims {
            _ = try delete(id: item.id)
        }
        return victims
    }

    /// 超量清理：保留最近 keepCount 条（未固定），返回被删除条目。
    func enforceLimit(keepCount: Int) throws -> [ContentItem] {
        let total = try count()
        guard total > keepCount else { return [] }
        // 找到超出配额的未固定条目（按时间正序 = 最旧先删）
        let overflow = try database.query(
            """
            SELECT * FROM contents WHERE is_pinned = 0 ORDER BY created_at DESC LIMIT -1 OFFSET ?
            """,
            [.int(keepCount)],
            map: Self.mapRow
        )
        for item in overflow {
            _ = try delete(id: item.id)
        }
        return overflow
    }

    /// 删除全部（清空历史，plan.md §2.7.4）。
    func deleteAll() throws -> [ContentItem] {
        let all = try database.query("SELECT * FROM contents", map: Self.mapRow)
        try database.run("DELETE FROM contents")
        return all
    }

    // MARK: - 行映射

    static func mapRow(_ row: SQLiteRow) -> ContentItem {
        let metadataJSON = row.string(7).flatMap { $0.data(using: .utf8) }
        let metadata: ContentMetadata
        if let data = metadataJSON,
           let decoded = try? JSONDecoder().decode(ContentMetadata.self, from: data) {
            metadata = decoded
        } else {
            metadata = .none
        }

        return ContentItem(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            type: ContentType(rawValue: row.string(1) ?? "") ?? .text,
            createdAt: Date(timeIntervalSince1970: row.double(2)),
            updatedAt: Date(timeIntervalSince1970: row.double(3)),
            storagePath: row.string(4),
            thumbnailPath: row.string(5),
            textContent: row.string(6),
            metadata: metadata,
            isPinned: row.bool(8),
            contentHash: row.string(9)
        )
    }
}

/// 内容哈希工具（去重）。
enum ContentHasher {
    /// 文本规范化哈希（trim；大小写保留——大小写差异可能是刻意内容，谨慎处理 plan.md §9.6）。
    static func hash(text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "t:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 二进制哈希（图片 PNG 等）。
    static func hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "d:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
