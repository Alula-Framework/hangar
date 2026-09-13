import Foundation
import Logging
import PostgresNIO
import Testing

import Hangar

/// The parent suite for sandboxed tests — the counterpart to
/// ``PostgresIntegrationSuite``, minus the thing that matters.
///
/// `PostgresIntegrationSuite` is `.serialized`, and that trait applies
/// *recursively* to everything nested inside it, because `withRepo` truncates
/// shared fixture tables and two suites doing that concurrently would delete
/// each other's rows. Sandboxed tests have no such hazard: they commit nothing,
/// so there is nothing to protect and no reason to serialize. Nesting under this
/// parent instead of that one is what actually buys the parallelism — leaving
/// them under the serialized parent would convert the isolation mechanism while
/// silently keeping the single-lane execution.
///
/// The DB gate is still inherited-by-nesting, so a new sandboxed suite only has
/// to remember where to nest.
@Suite(.enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct SandboxedIntegrationSuite {}

/// Runs `body` with a `Repo` pinned to one connection inside a transaction that
/// is **always rolled back** — the value-level equivalent of Ecto's
/// `Ecto.Adapters.SQL.Sandbox`.
///
/// Isolation comes from nothing ever being committed, rather than from wiping
/// shared tables. That is the whole difference from ``withRepo(_:)``: no
/// `TRUNCATE`, and therefore no `DatabaseLock`, and therefore sandboxed tests
/// can run *concurrently* with each other.
///
/// ## Why it is safe
///
/// The repo is built with `inTransaction: true`, which puts it at depth 1. A
/// `repo.transaction { }` inside `body` therefore renders as
/// `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` rather than `BEGIN`/`COMMIT` (see
/// `Transaction.swift`), so code under test **cannot commit its way out of the
/// sandbox**. Without that property this helper would be unsound.
///
/// ## What it cannot test
///
/// - **Serialization retry.** `retryingOnSerializationFailure` short-circuits
///   when already in a transaction, so retries never fire in here.
/// - **Cross-connection visibility.** Uncommitted rows are invisible to any
///   other connection: replica routing, `LISTEN`/`NOTIFY`, advisory locks and
///   any two-client test must use ``withRepo(_:)`` instead.
/// - **Generated sequence values.** Sequences do not roll back, so an assertion
///   on an exact `SERIAL`/identity value is not reproducible.
///
/// - Note: `body` is invoked *inside* the lease closure rather than passed
///   across it. Region isolation rejects the round trip — the same constraint
///   `Repo.transaction` documents.
func withSandbox<T: Sendable>(_ body: @Sendable (Repo) async throws -> T) async throws -> T {
    try await runSandbox(logger: nil, diagnostics: nil, body)
}

/// ``withSandbox(_:)`` with a logger and diagnostics attached — for the suites
/// that assert on what Hangar *reports* rather than on what it returns. The
/// counterpart to `withRepo(logger:diagnostics:)`.
func withSandbox<T: Sendable>(
    logger: Logger,
    diagnostics: QueryDiagnostics,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    try await runSandbox(logger: logger, diagnostics: diagnostics, body)
}

private func runSandbox<T: Sendable>(
    logger: Logger?,
    diagnostics: QueryDiagnostics?,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            // Idempotent and process-wide, so it costs nothing after the first
            // sandbox. Deliberately outside the transaction: DDL that rolled
            // back would leave every later sandbox without a schema.
            try await TestSchema.shared.ensure(client)
            let result = try await client.withConnection { connection in
                let log = logger ?? Logger(label: "hangar.sandbox")
                _ = try await connection.query("BEGIN", logger: log)
                do {
                    var repo = Repo(connection: connection, inTransaction: true, logger: logger)
                    if let diagnostics { repo.diagnostics = diagnostics }
                    let value = try await body(repo)
                    // Rolled back on the *success* path too: a sandbox never
                    // commits, so a passing test leaves exactly as little
                    // behind as a failing one.
                    _ = try? await connection.query("ROLLBACK", logger: log)
                    return value
                } catch {
                    _ = try? await connection.query("ROLLBACK", logger: log)
                    throw error
                }
            }
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Counts `hangar_posts` rows with `title`, on a connection of its own.
///
/// Used to check from *outside* a sandbox that nothing escaped it. Deliberately
/// not built on ``withRepo(_:)``: that truncates the fixture tables on entry,
/// which would destroy the very evidence these assertions are looking for.
func countPosts(titled title: String) async throws -> Int {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            let rows = try await client.query(
                "SELECT count(*) FROM \"hangar_posts\" WHERE title = \(title)",
                logger: nil)
            var count = 0
            for try await row in rows {
                count = try row.makeRandomAccess()[0].decode(Int.self)
            }
            group.cancelAll()
            return count
        } catch {
            group.cancelAll()
            throw error
        }
    }
}
