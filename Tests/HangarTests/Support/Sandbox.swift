import Foundation
import Logging
import PostgresNIO
import Testing

import Hangar
import HangarTesting

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

/// ``withSandbox(_:logger:diagnostics:_:)`` from `HangarTesting`, wrapped with
/// this suite's fixture client and schema.
///
/// The sandbox mechanics themselves now ship in the `HangarTesting` product —
/// this is only the part that is specific to Hangar's own fixtures: standing up a
/// client against `HANGAR_TEST_DATABASE_URL` and making sure the fixture schema
/// exists. Applications supply their own pool and call the shipped helper
/// directly.
func withSandbox<T: Sendable>(_ body: @Sendable (Repo) async throws -> T) async throws -> T {
    try await runSandbox(logger: nil, diagnostics: nil, body)
}

/// ``withSandbox(_:)`` with a logger and diagnostics attached — for the suites
/// that assert on what Hangar *reports* rather than on what it returns.
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
            // Idempotent and process-wide. Deliberately outside the sandbox
            // transaction: DDL that rolled back would leave every later sandbox
            // without a schema.
            try await TestSchema.shared.ensure(client)
            let result = try await HangarTesting.withSandbox(
                client, logger: logger, diagnostics: diagnostics, body)
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
