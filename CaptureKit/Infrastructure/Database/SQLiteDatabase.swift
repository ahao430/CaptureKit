import Foundation
import SQLite3

/// 轻量 SQLite 封装（sqlite3 C API）。
/// 所有操作在专用串行队列执行（design.md §13.2：数据库专用执行上下文）。
/// 迁移用 PRAGMA user_version（design.md §10.5：必须提供 migration 机制）。
final class SQLiteDatabase {
    enum DatabaseError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)
        case migration(String)

        var description: String {
            switch self {
            case .open(let message): return "sqlite open failed: \(message)"
            case .prepare(let message, let sql): return "sqlite prepare failed: \(message) [\(sql)]"
            case .step(let message, let sql): return "sqlite step failed: \(message) [\(sql)]"
            case .migration(let message): return "sqlite migration failed: \(message)"
            }
        }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.wanghao.capturekit.database", qos: .utility)

    let url: URL

    /// 打开（必要时创建目录与数据库）。
    init(url: URL) throws {
        self.url = url
        if url.path != ":memory:" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        handle = opened

        try executeUnsafe("PRAGMA journal_mode=WAL")
        try executeUnsafe("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - 迁移

    /// 按版本顺序应用迁移（幂等：user_version 已达标则跳过）。
    func migrate(migrations: [(version: Int, sql: String)]) throws {
        try onQueue { db in
            let current = try SQLiteDatabase.userVersion(db.handle)
            for migration in migrations where migration.version > current {
                do {
                    try SQLiteDatabase.execUnsafe(migration.sql, handle: db.handle)
                } catch {
                    throw DatabaseError.migration("version \(migration.version): \(error)")
                }
                try SQLiteDatabase.execUnsafe("PRAGMA user_version=\(migration.version)", handle: db.handle)
            }
        }
    }

    private static func userVersion(_ handle: OpaquePointer?) throws -> Int {
        let statement = try prepareUnsafe("PRAGMA user_version", handle: handle)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - 执行

    /// 无结果语句（DDL / 写入）。
    func execute(_ sql: String) throws {
        try onQueue { db in
            try SQLiteDatabase.execUnsafe(sql, handle: db.handle)
        }
    }

    /// 参数化写入。
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try onQueue { db in
            let statement = try SQLiteDatabase.prepareUnsafe(sql, handle: db.handle)
            defer { sqlite3_finalize(statement) }
            SQLiteDatabase.bind(bindings, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(db.handle)), sql: sql)
            }
        }
    }

    /// 参数化查询。
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        try onQueue { db in
            let statement = try SQLiteDatabase.prepareUnsafe(sql, handle: db.handle)
            defer { sqlite3_finalize(statement) }
            SQLiteDatabase.bind(bindings, to: statement)

            var results: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    results.append(try map(SQLiteRow(statement: statement)))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw DatabaseError.step(String(cString: sqlite3_errmsg(db.handle)), sql: sql)
                }
            }
            return results
        }
    }

    /// 事务。
    func transaction(_ body: () throws -> Void) throws {
        try onQueue { db in
            try SQLiteDatabase.execUnsafe("BEGIN IMMEDIATE", handle: db.handle)
            do {
                try body()
                try SQLiteDatabase.execUnsafe("COMMIT", handle: db.handle)
            } catch {
                try? SQLiteDatabase.execUnsafe("ROLLBACK", handle: db.handle)
                throw error
            }
        }
    }

    // MARK: - 私有

    private func onQueue<T>(_ work: (SQLiteDatabase) throws -> T) rethrows -> T {
        try queue.sync { try work(self) }
    }

    private func executeUnsafe(_ sql: String) throws {
        try SQLiteDatabase.execUnsafe(sql, handle: handle)
    }

    fileprivate static func execUnsafe(_ sql: String, handle: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw DatabaseError.step(message, sql: sql)
        }
    }

    fileprivate static func prepareUnsafe(_ sql: String, handle: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return statement
    }

    fileprivate static func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let int): sqlite3_bind_int64(statement, position, Int64(int))
            case .double(let double): sqlite3_bind_double(statement, position, double)
            case .text(let string): sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, position, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
    }
}

/// 绑定值。
enum SQLiteValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// 查询行读取器。
struct SQLiteRow {
    private let statement: OpaquePointer?

    init(statement: OpaquePointer?) {
        self.statement = statement
    }

    func int(_ index: Int) -> Int {
        Int(sqlite3_column_int64(statement, Int32(index)))
    }

    func double(_ index: Int) -> Double {
        sqlite3_column_double(statement, Int32(index))
    }

    func string(_ index: Int) -> String? {
        guard let cString = sqlite3_column_text(statement, Int32(index)) else { return nil }
        return String(cString: cString)
    }

    func blob(_ index: Int) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, Int32(index)) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, Int32(index)))
        return Data(bytes: bytes, count: count)
    }

    func bool(_ index: Int) -> Bool {
        int(index) != 0
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
