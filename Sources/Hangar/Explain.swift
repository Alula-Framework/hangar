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
    /// is the more useful of the two — but it executes, so a write statement
    /// writes. The `Query` overload of `Repo.explain` can only render a
    /// `SELECT`; the `SQLFragment` overload explains whatever it is given,
    /// and analyzing an `UPDATE` or `DELETE` there performs it. Nothing
    /// refuses that: pass a write only with `.plan`.
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
    public func explain<M: Table, R>(
        _ query: Query<M, R>, mode: ExplainMode = .plan
    ) async throws -> String {
        let rendered = SQLRenderer.select(query)
        return try await explain(sql: rendered.sql, binds: rendered.binds, mode: mode)
    }

    /// The plan for a raw fragment, for the statements the query builder does
    /// not express.
    ///
    /// Any statement is accepted, reads and writes alike. With `.analyze` a
    /// write is executed. Explaining routes as a read, so outside a
    /// transaction on a repo with a read replica the write goes to the
    /// replica, which refuses it.
    public func explain(_ fragment: SQLFragment, mode: ExplainMode = .plan) async throws -> String {
        var writer = BindWriter()
        let sql = SQLRenderer.render(.fragment(fragment.parts), writer: &writer)
        return try await explain(sql: sql, binds: writer.binds, mode: mode)
    }

    private func explain(sql: String, binds: [SQLBind], mode: ExplainMode) async throws -> String {
        let prefix = mode == .analyze ? "EXPLAIN (ANALYZE, BUFFERS) " : "EXPLAIN "
        let statement = RenderedStatement(sql: prefix + sql, binds: binds)
        // Read intent even for `.analyze`: explaining is diagnosis, and a
        // replica is the right place to do it when one is configured.
        let rows = try await execute(
            try statement.postgresQuery(), intent: .read, operation: "explain")
        var lines: [String] = []
        for try await line in rows.decode(String.self) { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
