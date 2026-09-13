import Foundation
import Testing

import Hangar

// Phase 1 of the testing plan: these tests *are* the specification of
// `withSandbox`. Each one corresponds to a gate criterion (G1.1–G1.5), and the
// primitive is only sound if all five hold.
//
// Nested under `SandboxedIntegrationSuite`, not `PostgresIntegrationSuite`:
// the latter is `.serialized` and that trait applies recursively, which would
// keep these in the single lane the sandbox exists to escape. No
// `DatabaseLock` either — the claim under test is that a sandbox needs neither.
//
// Every test tags its rows with a unique title so that rows left behind by the
// truncating suites can never satisfy or spoil an assertion here.

extension SandboxedIntegrationSuite {
@Suite("withSandbox — transactional test isolation")
struct SandboxTests {

    /// A title no other suite can collide with.
    private static func uniqueTitle(_ label: String) -> String {
        "sandbox-\(label)-\(UUID().uuidString)"
    }

    // MARK: G1.1 — it works

    @Test("G1.1: a sandboxed repo reads back its own writes")
    func writesAreVisibleInside() async throws {
        let title = Self.uniqueTitle("g1-1")
        try await withSandbox { repo in
            _ = try await repo.insert(Post.sample(title: title))
            let found = try await repo.all(Post.where { $0.title == title })
            #expect(found.count == 1)
            #expect(found.first?.title == title)
        }
    }

    // MARK: G1.2 — nothing survives

    @Test("G1.2: nothing written inside survives the sandbox")
    func writesDoNotEscape() async throws {
        let title = Self.uniqueTitle("g1-2")
        try await withSandbox { repo in
            _ = try await repo.insert(Post.sample(title: title))
            // Visible in here...
            #expect(try await repo.count(Post.where { $0.title == title }) == 1)
        }
        // ...and gone the moment the sandbox returned, as seen from a
        // different connection.
        #expect(try await countPosts(titled: title) == 0)
    }

    // MARK: G1.3 — nested transactions are savepoints

    /// The load-bearing property. If `repo.transaction { }` inside a sandbox
    /// emitted `BEGIN`/`ROLLBACK` instead of `SAVEPOINT`/`ROLLBACK TO`, the
    /// failing inner transaction would tear down the *whole* sandbox
    /// transaction and `before` would vanish along with `inner`. That it
    /// survives is the proof that code under test cannot commit — or roll back
    /// — its way out of the sandbox.
    @Test("G1.3: a failing nested transaction rolls back only itself")
    func nestedTransactionIsASavepoint() async throws {
        struct Boom: Error {}
        let before = Self.uniqueTitle("g1-3-before")
        let inner = Self.uniqueTitle("g1-3-inner")

        try await withSandbox { repo in
            _ = try await repo.insert(Post.sample(title: before))

            await #expect(throws: Boom.self) {
                try await repo.transaction { tx in
                    _ = try await tx.insert(Post.sample(title: inner))
                    throw Boom()
                }
            }

            // The savepoint rolled back: the inner row is gone,
            #expect(try await repo.count(Post.where { $0.title == inner }) == 0)
            // but the sandbox transaction itself is intact and still usable.
            #expect(try await repo.count(Post.where { $0.title == before }) == 1)
            _ = try await repo.insert(Post.sample(title: before))
            #expect(try await repo.count(Post.where { $0.title == before }) == 2)
        }

        #expect(try await countPosts(titled: before) == 0)
    }

    // MARK: G1.4 — a throwing body still cleans up

    @Test("G1.4: a body that throws propagates the error and leaves nothing")
    func throwingBodyStillRollsBack() async throws {
        struct Boom: Error {}
        let title = Self.uniqueTitle("g1-4")

        await #expect(throws: Boom.self) {
            try await withSandbox { repo in
                _ = try await repo.insert(Post.sample(title: title))
                throw Boom()
            }
        }

        #expect(try await countPosts(titled: title) == 0)
    }

    // MARK: G1.5 — no connection leak

    /// Each `withSandbox` stands up a client, leases a connection and tears the
    /// client down again. Repeating that is where a leak would show — as pool
    /// exhaustion or a wedged run rather than as a failed assertion — so the
    /// check is that ordinary work still succeeds afterwards.
    @Test("G1.5: repeated sandboxes do not leak connections")
    func repeatedSandboxesDoNotLeak() async throws {
        for index in 0..<50 {
            let title = Self.uniqueTitle("g1-5-\(index)")
            try await withSandbox { repo in
                _ = try await repo.insert(Post.sample(title: title))
                #expect(try await repo.count(Post.where { $0.title == title }) == 1)
            }
        }

        // Still healthy after 50 create/lease/rollback/destroy cycles.
        let after = Self.uniqueTitle("g1-5-after")
        try await withSandbox { repo in
            _ = try await repo.insert(Post.sample(title: after))
            #expect(try await repo.count(Post.where { $0.title == after }) == 1)
        }
        #expect(try await countPosts(titled: after) == 0)
    }
}
}
