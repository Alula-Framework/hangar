import Foundation
import PostgresNIO
import Testing

@testable import Hangar

// MARK: - SQL shapes

@Suite("Transactions — isolation and locking SQL")
struct TransactionRenderingTests {

    @Test("an isolation level lands on the outermost BEGIN, verbatim from the enum")
    func isolationOnBegin() {
        #expect(TransactionControl(depth: 0, isolation: .serializable).begin.sql
            == "BEGIN ISOLATION LEVEL SERIALIZABLE")
        #expect(TransactionControl(depth: 0, isolation: .repeatableRead).begin.sql
            == "BEGIN ISOLATION LEVEL REPEATABLE READ")
        #expect(TransactionControl(depth: 0, isolation: nil).begin.sql == "BEGIN")
    }

    @Test("a nested level is ignored — savepoints cannot change isolation")
    func isolationIgnoredOnSavepoints() {
        let control = TransactionControl(depth: 2, isolation: .serializable)
        #expect(control.begin.sql == "SAVEPOINT hangar_sp_2")
    }

    @Test("lockForUpdate renders FOR UPDATE at the end of the statement")
    func lockRendering() {
        let sql = SQLRenderer.select(Post.where { $0.published == true }.lockForUpdate()).sql
        #expect(sql.hasSuffix("FOR UPDATE"))
        let share = SQLRenderer.select(Post.all.lockForShare()).sql
        #expect(share.hasSuffix("FOR SHARE"))
    }

    @Test("a lock composed before a join carries through, not silently dropped")
    func lockSurvivesJoin() throws {
        let sql = try SQLRenderer.select(
            Post.all.lockForUpdate()
                .join(Comment.self, on: { p, c in c.postID == p.id })
        ).sql
        #expect(sql.hasSuffix("FOR UPDATE"))
    }

    @Test("count never locks the rows it counts")
    func countStripsLock() {
        let sql = SQLRenderer.count(Post.all.lockForUpdate().distinct()).sql
        #expect(!sql.contains("FOR UPDATE"))
    }

    @Test("bulk writes refuse a locking query — they take their own locks")
    func bulkRefusesLock() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.lockForUpdate())
        }
    }

    @Test("the escape hatch renders literals as SQL and values as binds")
    func escapeHatchBinds() {
        let statement = SQLRenderer.statement("SELECT pg_advisory_xact_lock(\(42))")
        #expect(statement.sql == "SELECT pg_advisory_xact_lock($1)")
        #expect(statement.binds.count == 1)
        // And it is NOT parenthesized like a fragment predicate would be.
        let set = SQLRenderer.statement("SET LOCAL statement_timeout = \(raw: "'5s'")")
        #expect(set.sql == "SET LOCAL statement_timeout = '5s'")
    }
}

// MARK: - Integration

/// Two tasks that must both pass a point before either proceeds.
///
/// One-shot on purpose: the first two arrivals are released together and every
/// arrival after that passes straight through. A *retried* transaction must not
/// block here — by then its partner has committed and the second arrival is
/// never coming.
private actor Rendezvous {
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        arrived += 1
        if arrived >= 2 {
            for waiter in waiters { waiter.resume() }
            waiters = []
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A one-way signal: `wait()` returns once `signal()` has been called, then and
/// forever after.
private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// How many times each slot's body ran — the evidence that a retry happened at
/// all, which "no failures" on its own does not provide.
private actor AttemptLog {
    private var counts: [String: Int] = [:]
    func record(_ slot: String) { counts[slot, default: 0] += 1 }
    func snapshot() -> [String: Int] { counts }
}

extension PostgresIntegrationSuite {
    @Suite("Transactions — isolation, retry, escape hatch (real Postgres)")
    struct TransactionFeatureIntegrationTests {

        /// Classic write-skew, with the loser *chosen* rather than raced.
        ///
        /// Both transactions snapshot both rows, then each updates the row the
        /// other read — the dependency edge SSI detects. Postgres aborts
        /// whichever commits second, so letting `a` commit first makes `b` the
        /// loser on every run.
        ///
        /// It used to let them race, and that made this suite's only evidence
        /// for retry a coin flip. When SSI aborts *both* sides, both retry at
        /// once, re-enter the same read-both/write-one pattern and conflict
        /// again — and the wrapper retries immediately with no backoff, so they
        /// can burn all three attempts against each other. Choosing the loser
        /// removes the race without weakening anything: the conflict is still
        /// real, produced by real SSI, and the wrapper under test is untouched.
        private func provokeWriteSkew(
            _ repo: Repo, retryAttempts: Int?
        ) async throws -> (failures: [String], values: [String], attempts: [String: Int]) {
            let gate = Rendezvous()
            let aCommitted = Latch()
            let attemptLog = AttemptLog()
            var sqlStates: [String] = []

            await withTaskGroup(of: (any Error)?.self) { group in
                for slot in ["a", "b"] {
                    group.addTask {
                        do {
                            let body: @Sendable (Repo) async throws -> Void = { tx in
                                await attemptLog.record(slot)
                                // Read BOTH rows, then write only ours —
                                // the other row's read is the dependency
                                // edge SSI detects.
                                let rows = try await tx.all(KV.all)
                                let total = rows.map(\.value).joined()
                                await gate.arrive()
                                // Both snapshots are taken. `b` now waits for
                                // `a` to commit, so `b` is the second committer
                                // and therefore the one SSI aborts.
                                if slot == "b" { await aCommitted.wait() }
                                _ = try await tx.update(KV.where { $0.key == slot }) {
                                    $0.value.set(to: "\(slot):saw-\(total.count)")
                                }
                            }
                            if let retryAttempts {
                                try await repo.transaction(
                                    isolation: .serializable,
                                    retryingOnSerializationFailure: retryAttempts,
                                    body)
                            } else {
                                try await repo.transaction(isolation: .serializable, body)
                            }
                            // After the transaction returns, so the commit has
                            // actually happened. Signalled on the failure path
                            // too — otherwise a failing `a` parks `b` forever.
                            if slot == "a" { await aCommitted.signal() }
                            return nil
                        } catch {
                            if slot == "a" { await aCommitted.signal() }
                            return error
                        }
                    }
                }
                for await failure in group {
                    if let psql = failure as? PSQLError,
                        let state = psql.serverInfo?[.sqlState]
                    {
                        sqlStates.append(state)
                    } else if let failure {
                        sqlStates.append("unexpected: \(failure)")
                    }
                }
            }
            let values = try await repo.all(KV.all.order { $0.key.asc() }).map(\.value)
            return (sqlStates, values, await attemptLog.snapshot())
        }

        @Test("serializable contention surfaces SQLSTATE 40001 without retry")
        func serializationFailureSurfaces() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "a", value: "0"))
                try await repo.insert(KV(key: "b", value: "0"))
                let (failures, _, attempts) = try await provokeWriteSkew(repo, retryAttempts: nil)
                #expect(failures == ["40001"], "exactly one side should fail, with 40001")
                // Without a retry wrapper each body runs exactly once. If this
                // ever reads higher, something is retrying that should not be.
                #expect(attempts == ["a": 1, "b": 1])
            }
        }

        @Test("the retry wrapper recovers the losing transaction")
        func retryRecovers() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "a", value: "0"))
                try await repo.insert(KV(key: "b", value: "0"))
                let (failures, values, attempts) = try await provokeWriteSkew(repo, retryAttempts: 3)
                #expect(failures.isEmpty, "both sides should succeed after retry")
                #expect(values.count == 2)
                #expect(values.allSatisfy { $0.contains("saw-") })
                // The assertions above pass just as happily if no conflict ever
                // occurred — "nothing failed" is not evidence that a retry
                // recovered anything, and this is the only test that covers a
                // feature whose CHANGELOG records it having shipped inert. `b`
                // is the chosen loser, so its body must have run at least twice.
                #expect(
                    attempts["b", default: 0] >= 2,
                    "b must actually have been aborted and retried, not merely have succeeded")
                #expect(attempts["a", default: 0] == 1, "a commits first and is never retried")
            }
        }

        @Test("execute runs on the transaction's own connection — SET LOCAL proves it")
        func escapeHatchConnectionAffinity() async throws {
            try await withRepo { repo in
                try await repo.transaction { tx in
                    try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
                    let rows = try await tx.execute("SHOW statement_timeout")
                    for try await row in rows {
                        let value = try row.makeRandomAccess()[0].decode(String.self)
                        #expect(value == "5s", "SET LOCAL must be visible on the same connection")
                    }
                }
            }
        }

        @Test("a held FOR UPDATE lock blocks a second locking read")
        func lockActuallyLocks() async throws {
            try await withRepo { repo in
                let stored = try await repo.insert(Post.sample(title: "contested"))
                let held = Rendezvous()
                let done = Rendezvous()

                await withTaskGroup(of: String?.self) { group in
                    group.addTask {
                        try? await repo.transaction { tx in
                            _ = try await tx.all(
                                Post.where { $0.id == stored.id }.lockForUpdate())
                            await held.arrive()  // lock is held
                            await done.arrive()  // hold it until B has failed
                        }
                        return nil
                    }
                    group.addTask {
                        await held.arrive()
                        defer { Task { await done.arrive() } }
                        do {
                            try await repo.transaction { tx in
                                // Fail fast instead of queueing behind A.
                                try await tx.execute("SET LOCAL lock_timeout = \(raw: "'200ms'")")
                                _ = try await tx.all(
                                    Post.where { $0.id == stored.id }.lockForUpdate())
                            }
                            return "acquired"
                        } catch let error as PSQLError {
                            return error.serverInfo?[.sqlState]
                        } catch {
                            return "unexpected"
                        }
                    }
                    var outcomes: [String?] = []
                    for await outcome in group { outcomes.append(outcome) }
                    // 55P03: lock_not_available — the lock was genuinely held.
                    #expect(outcomes.contains("55P03"))
                }
            }
        }
    }
}
