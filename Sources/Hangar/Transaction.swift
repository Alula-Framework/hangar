import Logging
import PostgresNIO

// Transactions. The `Repo` handed to the body is bound to the
// transaction's connection, so everything inside participates. Throwing
// rolls back; returning commits. Nested `transaction` calls become
// savepoints (`SAVEPOINT` / `RELEASE` / `ROLLBACK TO`), never nested
// `BEGIN`s.

/// A transaction's isolation level, applied to the outermost `BEGIN`.
///
/// Postgres ties isolation to the whole transaction — a savepoint cannot
/// change it — so the level is honored at depth zero and ignored on nested
/// `transaction { }` calls, exactly as `SET TRANSACTION` itself would be.
public enum IsolationLevel: String, Sendable {
    /// Postgres's default: each statement sees rows committed before it ran.
    case readCommitted = "READ COMMITTED"
    /// Every statement sees the snapshot the transaction started with.
    case repeatableRead = "REPEATABLE READ"
    /// Full serializability. Concurrent conflicting transactions fail with
    /// SQLSTATE 40001 and must be retried — see
    /// `transaction(isolation:retryingOnSerializationFailure:_:)`.
    case serializable = "SERIALIZABLE"
}

extension Repo {
    /// Runs `body` inside a transaction on one connection. Returning
    /// commits; throwing rolls back. Nested calls become savepoints.
    ///
    /// The `Repo` handed to `body` is bound to the transaction's
    /// connection — use it, not the outer repo, for everything inside, or
    /// the work runs outside the transaction.
    ///
    /// - Parameters:
    ///   - isolation: applied to the outermost `BEGIN`
    ///     (`BEGIN ISOLATION LEVEL SERIALIZABLE`); ignored on nested calls,
    ///     because Postgres ties isolation to the whole transaction and a
    ///     savepoint cannot change it.
    ///   - body: the transactional work, handed a `Repo` bound to the
    ///     transaction's connection.
    public func transaction<T: Sendable>(
        isolation: IsolationLevel? = nil,
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        switch backend {
        case .client(let primary, _):
            // One connection leased from the PRIMARY for the whole
            // transaction — a replica never sees writes — and every
            // statement in `body` runs on it. The control flow is inlined
            // here (rather than shared with the branch below) so `body` is
            // *called* inside the lease closure, never passed across it —
            // region isolation rejects the round trip.
            return try await primary.withConnection { connection in
                let control = TransactionControl(depth: 0, isolation: isolation)
                let log = logger ?? Self.quietLogger
                _ = try await connection.query(control.begin, logger: log)
                let tx = Repo(transaction: connection, depth: 1, logger: logger)
                do {
                    let result = try await body(tx)
                    _ = try await connection.query(control.commit, logger: log)
                    return result
                } catch {
                    // Roll back and surface the body's error. If the
                    // rollback itself fails the connection is beyond saving
                    // — the pool discards it, and the original error is
                    // still the story.
                    _ = try? await connection.query(control.rollback, logger: log)
                    throw error
                }
            }
        case .transaction(let connection, let depth):
            let control = TransactionControl(depth: depth, isolation: isolation)
            let log = logger ?? Self.quietLogger
            _ = try await connection.query(control.begin, logger: log)
            let tx = Repo(transaction: connection, depth: depth + 1, logger: logger)
            do {
                let result = try await body(tx)
                _ = try await connection.query(control.commit, logger: log)
                return result
            } catch {
                _ = try? await connection.query(control.rollback, logger: log)
                throw error
            }
        }
    }

    /// Runs `body` in a transaction, retrying the **whole transaction** when
    /// Postgres reports a serialization failure or deadlock.
    ///
    /// The standard `SERIALIZABLE` pattern: concurrent conflicting
    /// transactions are the isolation level working as designed, expressed
    /// as SQLSTATE `40001` (serialization_failure) or `40P01`
    /// (deadlock_detected), and the documented remedy is to run again.
    ///
    /// ```swift
    /// try await repo.transaction(
    ///     isolation: .serializable, retryingOnSerializationFailure: 3
    /// ) { tx in
    ///     let account = try await tx.one(Account.where { $0.id == id })
    ///     ...
    /// }
    /// ```
    ///
    /// `body` must therefore be safe to run more than once — it will be,
    /// on a fresh transaction, after every retryable failure short of the
    /// attempt limit. Side effects outside the database (a sent email, an
    /// enqueued job) do not roll back; keep them out of retried bodies.
    ///
    /// Attempts are separated by a short randomised wait — `0...10ms` before
    /// the first retry, doubling after that — so two transactions that
    /// conflicted do not retry in lockstep and collide again. Worst case the
    /// default three attempts add under 30ms; cancellation propagates out of
    /// the wait rather than being swallowed.
    ///
    /// Called on a repo already inside a transaction, this does not retry:
    /// a serialization failure dooms the *whole* transaction, and only its
    /// outermost owner can run it again.
    public func transaction<T: Sendable>(
        isolation: IsolationLevel? = nil,
        retryingOnSerializationFailure maxAttempts: Int,
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        // The condition is "am I already inside someone else's transaction",
        // which is what the paragraph above describes — not "which backend
        // am I". Those came apart when `Repo(connection:)` arrived: a repo
        // pinned to a leased connection has the `.transaction` backend at
        // depth 0, so it is *not* inside a transaction, and yet the old
        // `guard case .client` sent it down the no-retry path and discarded
        // `maxAttempts` in silence. That is the shape alula-data's
        // `withRepo` produces, and its own documentation recommends, so the
        // retry never fired for the idiom most callers use.
        guard !isInTransaction else {
            return try await transaction(isolation: isolation, body)
        }
        var attempt = 1
        while true {
            do {
                return try await transaction(isolation: isolation, body)
            } catch let error as PSQLError
                where attempt < maxAttempts && Self.isRetryableConflict(error)
            {
                // Wait a jittered moment rather than looping straight back in.
                //
                // Two transactions that serialization-conflict are, by
                // definition, running at the same time. Retrying both the
                // instant they fail re-runs the same overlap, and under SSI
                // the second collision is about as likely as the first — so a
                // pair can spend every attempt aborting each other and report
                // failure on work that would have succeeded alone. That is not
                // hypothetical: hangar's own retry test raced this way.
                //
                // Full jitter — uniform in `0...ceiling` rather than a fixed
                // delay — because a fixed backoff keeps the contenders in
                // lockstep, which is the thing being broken. The ceiling
                // doubles per attempt, so the default three attempts add under
                // 30ms in the worst case and usually a few milliseconds.
                //
                // Cancellation propagates out of the sleep, which is right: a
                // cancelled caller should not be held for a retry it no longer
                // wants.
                let ceiling = Self.retryBackoffBaseMilliseconds * (1 << (attempt - 1))
                try await Task.sleep(for: .milliseconds(Int.random(in: 0...ceiling)))
                attempt += 1
            }
        }
    }

    /// The first retry waits somewhere in `0...10ms`, the second `0...20ms`.
    /// Small on purpose: serialization contention is short-lived, and this
    /// sits in a request path.
    private static let retryBackoffBaseMilliseconds = 10

    /// SQLSTATE 40001 (serialization_failure) or 40P01 (deadlock_detected):
    /// the two "run it again" answers Postgres gives.
    private static func isRetryableConflict(_ error: PSQLError) -> Bool {
        let state = error.serverInfo?[.sqlState]
        return state == "40001" || state == "40P01"
    }
}

/// The statement triple for one nesting level: `BEGIN`/`COMMIT`/`ROLLBACK`
/// at the outermost level, savepoint forms inside. Savepoint names are
/// generated from the depth — never from user input.
struct TransactionControl {
    let begin: PostgresQuery
    let commit: PostgresQuery
    let rollback: PostgresQuery

    init(depth: Int, isolation: IsolationLevel? = nil) {
        if depth == 0 {
            // The level's SQL text comes from a closed enum, never from
            // user input — same rule as the savepoint names below.
            let level = isolation.map { " ISOLATION LEVEL \($0.rawValue)" } ?? ""
            begin = PostgresQuery(unsafeSQL: "BEGIN\(level)")
            commit = "COMMIT"
            rollback = "ROLLBACK"
        } else {
            let name = "hangar_sp_\(depth)"
            begin = PostgresQuery(unsafeSQL: "SAVEPOINT \(name)")
            commit = PostgresQuery(unsafeSQL: "RELEASE SAVEPOINT \(name)")
            rollback = PostgresQuery(unsafeSQL: "ROLLBACK TO SAVEPOINT \(name)")
        }
    }
}

/// Explicit rollback without a failure condition:
///
/// ```swift
/// throw RollbackError.intentional(reason)
/// ```
///
/// The transaction wrapper converts it to a rollback like any other thrown
/// error and rethrows it, so the caller can catch it and read the carried
/// value. Cleaner than Ecto's `Repo.rollback/1`, which needs a non-local
/// return mechanism — Swift's throws express it directly.
public enum RollbackError: Error, Sendable {
    case intentional(any Sendable)
}
