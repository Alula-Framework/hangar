import Foundation
import Logging
import PostgresNIO

import Hangar

/// Runs `body` with a ``Repo`` pinned to one connection inside a transaction
/// that is **always rolled back**.
///
/// This is the Swift equivalent of Ecto's `Ecto.Adapters.SQL.Sandbox`: test
/// isolation comes from nothing ever being committed, rather than from emptying
/// shared tables between tests. Two consequences follow, and both are the point:
///
/// - **No cleanup step.** There is nothing to truncate, because nothing was
///   written as far as any other connection is concerned.
/// - **Tests can run concurrently.** A truncate-based fixture needs a lock,
///   because one test emptying a table would delete another's rows mid-run. A
///   sandbox needs no lock, so suites can run in parallel.
///
/// ```swift
/// @Test("an overdrawn account is rejected")
/// func overdraft() async throws {
///     try await withSandbox(pool) { repo in
///         let account = try await repo.insert(Account.sample(balance: 10))
///         await #expect(throws: InsufficientFunds.self) {
///             try await Ledger(repo: repo).withdraw(50, from: account.id)
///         }
///     }
/// }
/// ```
///
/// ## Why it is safe
///
/// The repo is constructed with `inTransaction: true`, which places it at
/// transaction depth 1. A `repo.transaction { }` inside `body` therefore renders
/// as `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` rather than `BEGIN` / `COMMIT`, so
/// **code under test cannot commit its way out by opening its own transaction**.
/// Without that property this helper would be unsound rather than merely
/// convenient.
///
/// It is not a sandbox against arbitrary SQL, and this doc comment used to say
/// it was. `repo.execute("COMMIT")` ends the enclosing transaction and the rows
/// survive — verified by execution. The guarantee covers the transaction API,
/// which is what code under test realistically uses; a deliberate raw `COMMIT`
/// defeats it.
///
/// ## Scope your assertions
///
/// A sandbox empties nothing, so a query still sees every **committed** row in
/// the database. An assertion like `repo.count(User.all) == 3` is only true of an
/// otherwise-empty table; scope queries to the rows the test created
/// (`User.where { $0.id.in(ids) }`, or a per-test owner id) and the test becomes
/// independent of whatever else has run. That independence is what makes
/// parallel execution safe.
///
/// ## What a sandbox cannot test
///
/// - **Serialization-failure retry.** `retryingOnSerializationFailure`
///   short-circuits when already inside a transaction, so a retry never fires
///   here.
/// - **Anything needing a second connection.** Uncommitted rows are invisible
///   elsewhere, so read-replica routing, `LISTEN`/`NOTIFY`, advisory locks and
///   any two-client test must use a real committed fixture instead.
/// - **Commit durability itself.** A test whose *subject* is that a commit
///   persists, or that N savepoint levels unwind, will keep passing here while
///   measuring something else — the most dangerous case, because it is green.
/// - **Exact generated key values.** Sequences do not roll back, so an identity
///   column keeps advancing across sandboxes.
/// - **A statement that provokes a server error.** Postgres aborts the whole
///   transaction on any failed statement (`SQLSTATE 25P02`), so every query after
///   it throws instead of answering. A test that triggers a constraint violation
///   and then counts rows cannot run in a sandbox.
///
/// - Parameters:
///   - client: A running `PostgresClient`. Its lifetime belongs to the caller —
///     this function leases one connection from it and returns it on exit.
///   - logger: Attached to the repo, for tests that assert on what Hangar logs.
///   - diagnostics: Slow-query and repeated-query reporting, for the same.
///   - body: Receives the sandboxed repo. Called *inside* the connection lease.
/// - Returns: Whatever `body` returns.
/// - Note: `body` is invoked inside the lease closure rather than passed across
///   it, because region isolation rejects the round trip.
public func withSandbox<T: Sendable>(
    _ client: PostgresClient,
    logger: Logger? = nil,
    diagnostics: QueryDiagnostics? = nil,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    try await client.withConnection { connection in
        let log = logger ?? Logger(label: "hangar.sandbox")
        _ = try await connection.query("BEGIN", logger: log)
        do {
            var repo = Repo(connection: connection, inTransaction: true, logger: logger)
            if let diagnostics { repo.diagnostics = diagnostics }
            let value = try await body(repo)
            // Rolled back on the success path too: a sandbox never commits, so a
            // passing test leaves exactly as little behind as a failing one.
            _ = try? await connection.query("ROLLBACK", logger: log)
            return value
        } catch {
            _ = try? await connection.query("ROLLBACK", logger: log)
            throw error
        }
    }
}
