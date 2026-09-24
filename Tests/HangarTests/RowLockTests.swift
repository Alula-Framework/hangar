import Foundation
import PropertyBased
import Testing

@testable import Hangar

// Only FOR UPDATE and FOR SHARE existed, both waiting. The job-queue pattern —
// workers each claiming rows nobody else holds — needs SKIP LOCKED, a
// fail-fast read needs NOWAIT, and "read then change a non-key column" wants
// FOR NO KEY UPDATE so it does not block inserts that reference the row.

@Suite("Row-lock rendering")
struct RowLockRenderingTests {
    @Test(arguments: [RowLockStrength.update, .noKeyUpdate, .share, .keyShare], [RowLockWait.wait, .noWait, .skipLocked])
    func clause(strength: RowLockStrength, wait: RowLockWait) throws {
        let strengthSQL = ["FOR UPDATE", "FOR NO KEY UPDATE", "FOR SHARE", "FOR KEY SHARE"][
            [RowLockStrength.update, .noKeyUpdate, .share, .keyShare].firstIndex(of: strength)!]
        let waitSQL = ["", " NOWAIT", " SKIP LOCKED"][[RowLockWait.wait, .noWait, .skipLocked].firstIndex(of: wait)!]
        let sql = try Post.all.limit(1).lock(strength, wait: wait).renderedQuery().sql
        #expect(sql.hasSuffix("LIMIT 1 \(strengthSQL)\(waitSQL)"), "\(sql)")
    }

    @Test("the old spellings are unchanged")
    func compatibility() throws {
        #expect(try Post.all.lockForUpdate().renderedQuery().sql.hasSuffix("FOR UPDATE"))
        #expect(try Post.all.lockForShare().renderedQuery().sql.hasSuffix("FOR SHARE"))
    }
}

extension RowLockStrength: Equatable {}
extension RowLockWait: Equatable {}

/// Opens once, for everyone waiting and everyone after.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pass() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func openUp() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

extension PostgresIntegrationSuite {
    @Suite("Row locks against Postgres")
    struct RowLockIntegrationTests {
        @Test("NOWAIT fails at once and SKIP LOCKED steps around a held row")
        func noWaitAndSkip() async throws {
            try await withRepo { repo in
                for key in ["a", "b", "c"] { try await repo.insert(KV(key: key, value: "ready")) }
                let held = Gate()
                let release = Gate()
                async let holder: Void = repo.transaction { tx in
                    _ = try await tx.all(KV.where { $0.key == "a" }.lockForUpdate())
                    await held.openUp()
                    await release.pass()
                }
                await held.pass()
                let skipped = try await repo.transaction { tx in
                    try await tx.all(KV.all.order { $0.key.asc() }.lockForUpdate(wait: .skipLocked)).map(\.key)
                }
                var noWait: DatabaseError?
                do {
                    _ = try await repo.transaction { tx in
                        try await tx.all(KV.where { $0.key == "a" }.lockForUpdate(wait: .noWait))
                    }
                } catch let error as DatabaseError {
                    noWait = error
                }
                await release.openUp()
                try await holder
                #expect(skipped == ["b", "c"])
                #expect(noWait?.kind == .lockNotAvailable)
            }
        }

        @Test("workers claiming with SKIP LOCKED process every job exactly once")
        func queueDrainsExactlyOnce() async throws {
            try await withRepo { repo in
                await propertyCheck(count: 8, input: Gen.int(in: 1...40), Gen.int(in: 2...6)) { jobs, workers in
                    try await repo.execute(#"DELETE FROM "hangar_kv""#)
                    _ = try await repo.insert((0..<jobs).map { KV(key: String(format: "job-%03d", $0), value: "ready") })
                    let claims = try await withThrowingTaskGroup(of: [String].self) { group in
                        for worker in 0..<workers {
                            group.addTask {
                                var mine: [String] = []
                                while true {
                                    let claimed: String? = try await repo.transaction { tx in
                                        guard var job = try await tx.all(
                                            KV.where { $0.value == "ready" }.order { $0.key.asc() }.limit(1)
                                                .lockForUpdate(wait: .skipLocked)).first
                                        else { return nil }
                                        job.value = "done-by-\(worker)"
                                        try await tx.update(job)
                                        return job.key
                                    }
                                    guard let claimed else { return mine }
                                    mine.append(claimed)
                                }
                            }
                        }
                        var all: [String] = []
                        for try await mine in group { all += mine }
                        return all
                    }
                    #expect(claims.count == jobs, "\(workers) workers, \(jobs) jobs")
                    #expect(Set(claims).count == jobs, "a job was claimed twice")
                    #expect(try await repo.count(KV.where { $0.value == "ready" }) == 0)
                }
            }
        }
    }
}
