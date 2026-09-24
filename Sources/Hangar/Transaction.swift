import Logging
import PostgresNIO
import Synchronization

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
    ///   - statementTimeout: the longest any one statement in the
    ///     transaction may run, enforced by the server (`SET LOCAL
    ///     statement_timeout`); a statement past it fails with
    ///     ``DatabaseError/Kind/queryCanceled``. This is the way to bound a
    ///     query: cancelling the calling task does **not** stop it —
    ///     PostgresNIO sends no cancel request, so the server finishes the
    ///     statement and only then does the task see `CancellationError`.
    ///     Applied at the outermost level; ignored on nested calls, since a
    ///     setting made inside a savepoint outlives its `RELEASE`.
    ///   - body: the transactional work, handed a `Repo` bound to the
    ///     transaction's connection.
    public func transaction<T: Sendable>(
        isolation: IsolationLevel? = nil,
        statementTimeout: Duration? = nil,
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
                let control = TransactionControl(depth: 0, isolation: isolation, statementTimeout: statementTimeout)
                let log = logger ?? Self.quietLogger
                let ledger = TransactionLedger()
                try await control.run(\.begin, on: connection, logger: log)
                let tx = Repo(transaction: connection, depth: 1, ledger: ledger, logger: logger)
                do {
                    try await control.applySettings(on: connection, logger: log)
                    let result = try await body(tx)
                    try await control.finish(on: connection, ledger: ledger, logger: log)
                    return result
                } catch {
                    // Roll back and surface the body's error. If the
                    // rollback itself fails the connection is beyond saving
                    // — the pool discards it, and the original error is
                    // still the story.
                    let surfaced = control.surface(error, ledger: ledger)
                    await control.rollBack(on: connection, ledger: ledger, logger: log)
                    throw surfaced
                }
            }
        case .transaction(let connection, let depth):
            let control = TransactionControl(depth: depth, isolation: isolation, statementTimeout: statementTimeout)
            let log = logger ?? Self.quietLogger
            let ledger = transactionLedger ?? TransactionLedger()
            do {
                try await control.run(\.begin, on: connection, logger: log)
            } catch {
                // A SAVEPOINT refused because the enclosing transaction is
                // already aborted: say so, with the cause.
                throw control.surface(error, ledger: ledger)
            }
            let tx = Repo(transaction: connection, depth: depth + 1, ledger: ledger, logger: logger)
            do {
                try await control.applySettings(on: connection, logger: log)
                let result = try await body(tx)
                try await control.finish(on: connection, ledger: ledger, logger: log)
                return result
            } catch {
                let surfaced = control.surface(error, ledger: ledger)
                await control.rollBack(on: connection, ledger: ledger, logger: log)
                throw surfaced
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
        statementTimeout: Duration? = nil,
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
            return try await transaction(isolation: isolation, statementTimeout: statementTimeout, body)
        }
        var attempt = 1
        while true {
            do {
                return try await transaction(isolation: isolation, statementTimeout: statementTimeout, body)
            } catch let error as DatabaseError where attempt < maxAttempts && error.isRetryable {
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

}

/// The statement triple for one nesting level: `BEGIN`/`COMMIT`/`ROLLBACK`
/// at the outermost level, savepoint forms inside. Savepoint names are
/// generated from the depth — never from user input.
struct TransactionControl {
    /// The depth of the repo that opened this level: 0 for `BEGIN`, ≥1 for
    /// a savepoint. Statements *inside* the level run one deeper.
    let depth: Int
    let begin: PostgresQuery
    let commit: PostgresQuery
    let rollback: PostgresQuery
    /// `SET LOCAL …` statements run right after `BEGIN`.
    let settings: [PostgresQuery]

    init(depth: Int, isolation: IsolationLevel? = nil, statementTimeout: Duration? = nil) {
        self.depth = depth
        // Outermost only, like isolation: a SET LOCAL inside a savepoint
        // survives its RELEASE and would leak into the enclosing work. The
        // value is an integer Hangar renders, never user text.
        if depth == 0, let statementTimeout {
            let (seconds, attoseconds) = statementTimeout.components
            let milliseconds = max(1, seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
            settings = [PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = \(milliseconds)")]
        } else {
            settings = []
        }
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

    func applySettings(on connection: PostgresConnection, logger: Logger) async throws {
        for setting in settings {
            do {
                _ = try await connection.query(setting, logger: logger)
            } catch {
                throw translatingDatabaseErrors(error)
            }
        }
    }

    func run(
        _ statement: KeyPath<TransactionControl, PostgresQuery>, on connection: PostgresConnection,
        logger: Logger
    ) async throws {
        do {
            _ = try await connection.query(self[keyPath: statement], logger: logger)
        } catch {
            throw translatingDatabaseErrors(error)
        }
    }

    /// Commits the level, or throws if Postgres will not.
    ///
    /// **A `COMMIT` can succeed without committing.** Once any statement in
    /// a transaction fails, Postgres aborts the whole transaction; if the
    /// body caught that failure and returned normally, the `COMMIT` that
    /// follows is answered with the command tag `ROLLBACK` and *no error*.
    /// Reading only for errors, the caller would be told its work was saved
    /// when none of it was — the one failure mode a transaction exists to
    /// rule out. The tag is therefore checked, and a `ROLLBACK` answer throws
    /// ``HangarError/transactionAborted(cause:)`` naming the statement that
    /// failed.
    ///
    /// A savepoint has the same hazard with a louder symptom: `RELEASE` in
    /// an aborted transaction fails with SQLSTATE 25P02. That is mapped to
    /// the same error, so both levels say the same true thing.
    ///
    /// **A cancelled task does not commit.** Cancellation is cooperative, and
    /// PostgresNIO does not stop a running statement, so a body can run to
    /// its end after its task was cancelled — typically because the request
    /// it served went away. Committing that work would make durable what the
    /// caller abandoned; the outermost level checks first and throws
    /// `CancellationError`, which rolls the transaction back.
    func finish(on connection: PostgresConnection, ledger: TransactionLedger, logger: Logger) async throws {
        if depth == 0 {
            try Task.checkCancellation()
            let result: PostgresQueryResult
            do {
                result = try await connection.query(commit, logger: logger).get()
            } catch {
                throw translatingDatabaseErrors(error)
            }
            if result.metadata.command == "ROLLBACK" {
                throw HangarError.transactionAborted(cause: ledger.firstFailure)
            }
        } else {
            do {
                _ = try await connection.query(commit, logger: logger)
            } catch {
                throw surface(error, ledger: ledger)
            }
        }
    }

    /// The error a failed level reports. Server errors become
    /// ``DatabaseError``; SQLSTATE 25P02 — "current transaction is aborted"
    /// — becomes ``HangarError/transactionAborted(cause:)`` naming the
    /// statement that actually failed, because 25P02 is only ever the
    /// consequence of an earlier failure and on its own sends someone looking
    /// in the wrong place.
    func surface(_ error: any Error, ledger: TransactionLedger) -> any Error {
        let translated = translatingDatabaseErrors(error)
        if let database = translated as? DatabaseError, database.kind == .transactionAborted {
            return HangarError.transactionAborted(cause: ledger.firstFailure)
        }
        return translated
    }

    /// Rolls the level back. Never throws: this runs while another error is
    /// already on its way out, and that error is the one worth reporting.
    ///
    /// A successful `ROLLBACK TO SAVEPOINT` repairs an aborted transaction —
    /// statements after it run normally — so the failures recorded inside
    /// the savepoint are forgotten; they can no longer be the reason a later
    /// `COMMIT` refuses.
    func rollBack(on connection: PostgresConnection, ledger: TransactionLedger, logger: Logger) async {
        do {
            _ = try await connection.query(rollback, logger: logger)
            ledger.forget(deeperThan: depth)
        } catch {
            // The connection is beyond saving; the pool discards it.
        }
    }
}

/// The failed statements of one transaction, shared by the repos of all its
/// levels.
///
/// It exists so an aborted transaction can explain itself. By the time
/// `COMMIT` is refused, the statement that doomed the transaction is long
/// gone — typically caught and ignored in the body — and "transaction
/// aborted" with no cause sends someone hunting.
final class TransactionLedger: Sendable {
    private let failures = Mutex<[(depth: Int, error: DatabaseError)]>([])

    func record(_ error: DatabaseError, depth: Int) {
        // 25P02 is the *consequence* of an earlier failure, never the cause.
        guard error.kind != .transactionAborted else { return }
        failures.withLock { $0.append((depth, error)) }
    }

    /// The earliest failure no savepoint rollback has repaired — the one
    /// that aborted the transaction.
    var firstFailure: DatabaseError? {
        failures.withLock { $0.first?.error }
    }

    func forget(deeperThan depth: Int) {
        failures.withLock { $0.removeAll { $0.depth > depth } }
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
