import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String)
    public var description: String {
        switch self {
        case .open(let m): "打开数据库失败: \(m)"
        case .prepare(let m): "SQL 准备失败: \(m)"
        case .step(let m): "SQL 执行失败: \(m)"
        }
    }
}

/// 极薄的 SQLite 封装。刻意不引第三方库：
/// 一个会读取用户凭据的开源工具，零供应链面本身就是可信度的一部分。
public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA temp_store=MEMORY")
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.step("\(m) — \(sql.prefix(120))")
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare("\(String(cString: sqlite3_errmsg(handle))) — \(sql.prefix(120))")
        }
        return Statement(stmt)
    }

    /// 一次性查询，逐行回调。
    public func query(_ sql: String, _ binds: [Value] = [], row: (Row) -> Void) throws {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        stmt.bind(binds)
        while try stmt.step() { row(Row(stmt)) }
    }

    public enum Value: Sendable {
        case int(Int), double(Double), text(String), null
    }

    public final class Statement {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }

        public func bind(_ values: [Value]) {
            sqlite3_reset(raw)
            sqlite3_clear_bindings(raw)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case .int(let n): sqlite3_bind_int64(raw, idx, Int64(n))
                case .double(let d): sqlite3_bind_double(raw, idx, d)
                case .text(let s): sqlite3_bind_text(raw, idx, s, -1, SQLITE_TRANSIENT)
                case .null: sqlite3_bind_null(raw, idx)
                }
            }
        }

        @discardableResult
        public func step() throws -> Bool {
            switch sqlite3_step(raw) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw DatabaseError.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(raw))))
            }
        }

        public func run(_ values: [Value]) throws {
            bind(values)
            while try step() {}
        }

        public func finalize() { sqlite3_finalize(raw) }
    }

    public struct Row {
        let stmt: Statement
        init(_ s: Statement) { stmt = s }
        public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt.raw, i)) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt.raw, i) }
        /// NULL 敏感版本。成本列必须用它 —— 把“没有定价”读成 0 会让用户以为自己没花钱。
        public func doubleOrNil(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt.raw, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt.raw, i)
        }
        public func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt.raw, i).map { String(cString: $0) }
        }
    }
}
