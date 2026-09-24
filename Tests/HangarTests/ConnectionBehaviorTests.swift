import Foundation
import PostgresNIO
import Testing

@testable import Hangar

// Behavior that only shows under time, contention or cancellation — each of
// which the audit found untested: deadlock retry (only 40001 was exercised),
// optimistic locking against a real row, what cancelling a query does, and
// whether a small pool survives more transactions than it has connections.

private actor Barrier {
    private let parties: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ parties: Int) { self.parties = parties }
    func arrive() async {
        arrived += 1
        if arrived >= parties {
            waiters.forEach { $0.resume() }
            waiters = []
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

extension PostgresIntegrationSuite {
    @Suite("Connections under pressure (real Postgres)")
    struct ConnectionBehaviorTests {
        @Test("a statement past statementTimeout fails typed, and the setting ends with the transaction")
        func statementTimeout() async throws {
            try await withRepo { repo in
                let start = ContinuousClock.now
                await #expect {
                    try await repo.transaction(statementTimeout: .milliseconds(100)) { tx in
                        _ = try await tx.execute("SELECT pg_sleep(5)").collect()
                    }
                } throws: { ($0 as? DatabaseError)?.kind == .queryCanceled }
                #expect(ContinuousClock.now - start < .seconds(3))
                try await repo.transaction { tx in
                    for try await value in try await tx.execute("SHOW statement_timeout").decode(String.self) {
                        #expect(value == "0", "SET LOCAL must not outlive its transaction")
                    }
                }
            }
        }

        @Test("a cancelled transaction rolls back and returns its connection clean")
        func cancellation() async throws {
            try await withRepo { repo in
                let task = Task {
                    try await repo.transaction { tx in
                        try await tx.insert(KV(key: "cancelled", value: "x"))
                        _ = try await tx.execute("SELECT pg_sleep(1)").collect()
                        try await tx.insert(KV(key: "after", value: "x"))
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
                task.cancel()
                // The server finishes the sleep — PostgresNIO sends no cancel
                // request — and the task then reports its cancellation.
                let outcome = await task.result
                #expect((try? outcome.get()) == nil, "a cancelled transaction must not report success")
                #expect(try await repo.count(KV.all) == 0, "nothing from a cancelled transaction survives")
                for try await idle in try await repo.execute(
                    "SELECT count(*)::int FROM pg_stat_activity WHERE state = 'idle in transaction' AND datname = current_database()"
                ).decode(Int.self) {
                    #expect(idle == 0, "a connection went back to the pool inside a transaction")
                }
            }
        }

        @Test("deadlock victims are retried, and both transactions land")
        func deadlockRetry() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "a", value: "0"))
                try await repo.insert(KV(key: "b", value: "0"))
                let bothHoldOne = Barrier(2)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (first, second, mark) in [("a", "b", "x"), ("b", "a", "y")] {
                        group.addTask {
                            var attempt = 0
                            try await repo.transaction(retryingOnSerializationFailure: 3) { tx in
                                attempt += 1
                                try await tx.execute(#"UPDATE "hangar_kv" SET "value" = "value" || \#(mark) WHERE "key" = \#(first)"#)
                                // Only the first attempt meets the other: that is the deadlock.
                                if attempt == 1 { await bothHoldOne.arrive() }
                                try await tx.execute(#"UPDATE "hangar_kv" SET "value" = "value" || \#(mark) WHERE "key" = \#(second)"#)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                let values = try await repo.all(KV.all.order { $0.key.asc() }).map(\.value)
                // Each row got both marks exactly once, in some order.
                #expect(values.allSatisfy { $0.count == 3 && $0.contains("x") && $0.contains("y") }, "\(values)")
            }
        }

        @Test("an optimistic lock refuses a write based on a stale version")
        func optimisticLock() async throws {
            try await UpsertIntegrationTests.withDocs { repo in
                let original = try await repo.insert(UpsertIntegrationTests.doc("a", 1))
                let first = try await repo.update(
                    Changeset(original: original).change(\.body, "first writer").optimisticLock(\.version))
                #expect(first.version == 2)
                await #expect(throws: ChangesetConflictError.self) {
                    try await repo.update(
                        Changeset(original: original).change(\.body, "stale writer").optimisticLock(\.version))
                }
                #expect(try await repo.one(UpsertDoc.where { $0.id == original.id })?.body == "first writer")
            }
        }

        @Test("a two-connection pool serves many concurrent transactions without stalling")
        func smallPool() async throws {
            var configuration = try TestDatabase.clientConfiguration()
            configuration.options.maximumConnections = 2
            let client = PostgresClient(configuration: configuration)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await client.run() }
                let repo = Repo(client: client)
                try await DatabaseLock.shared.exclusive {
                    try await clearFixtureTables(client)
                    try await withThrowingTaskGroup(of: Void.self) { writers in
                        for index in 0..<24 {
                            writers.addTask {
                                try await repo.transaction { tx in
                                    try await tx.insert(KV(key: "k\(index)", value: "v"))
                                    _ = try await tx.execute("SELECT pg_sleep(0.01)").collect()
                                }
                            }
                        }
                        try await writers.waitForAll()
                    }
                    #expect(try await repo.count(KV.all) == 24)
                }
                group.cancelAll()
            }
        }
    }
}
