import Foundation
import PostgresNIO

/// How much work `EXPLAIN` should do.
public enum ExplainMode: Sendable, Equatable {
    /// Plan only. The query is not run, so this is safe against anything —
    /// including a `DELETE` you would rather not perform.
    case plan
    /// `EXPLAIN ANALYZE`: **runs the query** and reports what actually
    /// happened, including real row counts and timings.
    ///
    /// The estimate and the reality diverging is usually the answer, so this
    /// is the more useful of the two — but it executes, so it is refused for
    /// anything that may write: ``HangarError/explainAnalyzeWrite``
    /// (`HGR-QUERY-4115`), thrown before anything is sent. A write is still
    /// explained with `.plan`.
    case analyze
}

extension Repo {
    /// The query plan for `query`, as Postgres reports it.
    ///
    /// The diagnostics in ``QueryDiagnostics`` say *which* statement is slow.
    /// This says why — whether the index was used, where the row estimate went
    /// wrong, which join strategy was chosen:
    ///
    ///     let plan = try await repo.explain(
    ///         Post.where { $0.authorID == id }.order { $0.createdAt.desc() },
    ///         mode: .analyze)
    ///     print(plan)
    ///
    /// Returns the plan as text, one line per node, exactly as `psql` shows
    /// it — deliberately not parsed. A plan is something a human reads, and a
    /// structured representation would be a second thing to keep in step with
    /// Postgres's output across versions.
    ///
    /// A query is always a `SELECT`, but a raw CTE body — `with(_:as:)`
    /// given a fragment — can hide a write in it, so the rendered statement
    /// is classified the way a fragment is. A row lock is not a write: the
    /// plan comes from the primary, as the rows of `all` do, and `.analyze`
    /// is allowed.
    public func explain<M: Table, R>(
        _ query: Query<M, R>, mode: ExplainMode = .plan
    ) async throws -> String {
        let rendered = SQLRenderer.select(query)
        // Classified without the lock, whose `FOR UPDATE` would read as a write.
        var unlocked = query
        unlocked.rowLock = nil
        let writes = !ExplainTarget.isRead(SQLRenderer.select(unlocked).sql)
        return try await explain(
            sql: rendered.sql, binds: rendered.binds, mode: mode, writes: writes,
            intent: writes || query.rowLock != nil ? .write : .read)
    }

    /// The plan for a raw fragment, for the statements the query builder does
    /// not express.
    ///
    /// Reads and writes are both accepted, and a write's plan comes from the
    /// primary. Only `SELECT`, `VALUES`, `TABLE`, and a `WITH` with no
    /// `INSERT`, `UPDATE`, `DELETE` or `MERGE` in it count as reads, after
    /// any leading comments; anything else — `SELECT … INTO`, a locking
    /// `SELECT`, `EXECUTE` — is treated as a write. `.analyze` of a write is
    /// refused with ``HangarError/explainAnalyzeWrite`` rather than
    /// performed: to measure one, run `EXPLAIN ANALYZE` through
    /// `execute` inside a `transaction { }` that throws
    /// ``RollbackError/intentional(_:)``.
    public func explain(_ fragment: SQLFragment, mode: ExplainMode = .plan) async throws -> String {
        // Unparenthesized: `EXPLAIN (DELETE …)` is a syntax error.
        let rendered = SQLRenderer.statement(fragment)
        let writes = !ExplainTarget.isRead(rendered.sql)
        return try await explain(
            sql: rendered.sql, binds: rendered.binds, mode: mode, writes: writes,
            intent: writes ? .write : .read)
    }

    private func explain(
        sql: String, binds: [SQLBind], mode: ExplainMode, writes: Bool, intent: Intent
    ) async throws -> String {
        // `EXPLAIN ANALYZE` executes. Refused rather than trusted to a
        // transaction the caller may or may not roll back.
        if mode == .analyze, writes { throw HangarError.explainAnalyzeWrite }
        let prefix = mode == .analyze ? "EXPLAIN (ANALYZE, BUFFERS) " : "EXPLAIN "
        let statement = RenderedStatement(sql: prefix + sql, binds: binds)
        // A read's plan comes from the replica when one is configured —
        // explaining is diagnosis — and a write's from the primary, since a
        // replica refuses to plan a write it could not run.
        let rows = try await execute(
            try statement.postgresQuery(), intent: intent, operation: "explain")
        var lines: [String] = []
        for try await line in rows.decode(String.self) { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

/// Whether a statement is certainly a read — what `explain` decides routing
/// and `.analyze` on. Conservative by design: anything it cannot be sure of
/// counts as a write, because the cost of that is a plan from the primary or
/// a refused `.analyze`, and the cost of the opposite is a write performed.
enum ExplainTarget {
    /// Words that make a statement a write wherever they appear: the
    /// data-modifying statements a `WITH` can carry, `INTO` for
    /// `SELECT … INTO`, and `SHARE` for `FOR SHARE` (`FOR UPDATE` is caught
    /// by `UPDATE`).
    static let writing: Set<Substring> = ["INSERT", "UPDATE", "DELETE", "MERGE", "INTO", "SHARE"]

    /// `SELECT`, `VALUES` or `TABLE` first, or `WITH`, and none of
    /// ``writing`` anywhere outside comments, string literals and quoted
    /// identifiers — which is why this lexes rather than searching the text:
    /// a column named `"share"` must not read as a write. What it does not
    /// lex — a dollar-quoted string, a literal with a backslash in it, an
    /// unterminated anything — makes the statement a write.
    static func isRead(_ sql: String) -> Bool {
        let text = Array(sql.utf8)
        var words: [Substring] = []
        var i = 0
        func at(_ offset: Int) -> UInt8? { i + offset < text.count ? text[i + offset] : nil }
        func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x24 || byte >= 0x80
        }
        while i < text.count {
            switch text[i] {
            case UInt8(ascii: "-") where at(1) == UInt8(ascii: "-"):
                while i < text.count, text[i] != UInt8(ascii: "\n") { i += 1 }
            case UInt8(ascii: "/") where at(1) == UInt8(ascii: "*"):
                var depth = 0
                repeat {
                    guard i + 1 < text.count else { return false }
                    if text[i] == UInt8(ascii: "/"), text[i + 1] == UInt8(ascii: "*") {
                        depth += 1
                        i += 2
                    } else if text[i] == UInt8(ascii: "*"), text[i + 1] == UInt8(ascii: "/") {
                        depth -= 1
                        i += 2
                    } else {
                        i += 1
                    }
                } while depth > 0
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                // A doubled quote is the escape, and reads as two literals
                // back to back — the same answer.
                let quote = text[i]
                i += 1
                while i < text.count, text[i] != quote {
                    if text[i] == UInt8(ascii: "\\") { return false }
                    i += 1
                }
                guard i < text.count else { return false }
                i += 1
            case UInt8(ascii: "$"):
                // `$1` is a bind; `$tag$` opens a dollar-quoted string.
                guard let next = at(1), next >= 0x30, next <= 0x39 else { return false }
                i += 1
            case let byte where isWordByte(byte):
                let start = i
                while i < text.count, isWordByte(text[i]) { i += 1 }
                words.append(Substring(String(decoding: text[start..<i], as: UTF8.self).uppercased()))
            default:
                i += 1
            }
        }
        guard let first = words.first, ["SELECT", "VALUES", "TABLE", "WITH"].contains(first) else {
            return false
        }
        return !words.contains { writing.contains($0) }
    }
}
