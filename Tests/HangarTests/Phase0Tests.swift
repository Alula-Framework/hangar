import Foundation
import Testing

@testable import Hangar

// MARK: - Bulk delete rendering

@Suite("Bulk delete — SQL")
struct BulkDeleteRendererTests {

    @Test("delete(query) renders DELETE ... WHERE ... RETURNING pk")
    func rendersPredicateDelete() throws {
        let statement = try SQLRenderer.delete(Post.where { $0.published == false })
        #expect(
            statement.sql
                == #"DELETE FROM "hangar_posts" WHERE ("published" = $1) RETURNING "id""#)
        #expect(statement.binds.count == 1)
    }

    @Test("a query with no predicate deletes the whole table — explicitly")
    func wholeTable() throws {
        let statement = try SQLRenderer.delete(Post.all)
        #expect(statement.sql == #"DELETE FROM "hangar_posts" RETURNING "id""#)
    }

    @Test("clauses DELETE cannot honor are refused, naming the clause")
    func refusesUnsupportedClauses() throws {
        // A delete that ignored the LIMIT you wrote would delete rows you
        // did not ask it to — the silent-wrong-answer shape this library
        // refuses on principle.
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.limit(5))
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.offset(5))
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.order { $0.id.asc() })
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.groupBy { $0.authorID })
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.distinct())
        }
        do {
            _ = try SQLRenderer.delete(Post.all.limit(5))
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("LIMIT"))
        }
    }
}

// MARK: - SQLFragment column qualification

@Suite("SQLFragment — column qualification")
struct FragmentQualificationTests {

    @Test("in a single-table scope a fragment column renders bare")
    func singleTableBare() {
        let statement = SQLRenderer.select(
            Post.where { p in SQLFragment("char_length(\(p.title)) > \(3)") })
        #expect(statement.sql.contains(#"char_length("title")"#))
        #expect(statement.binds.count == 1)
    }

    @Test("inside a join a fragment column renders table-qualified")
    func joinQualified() throws {
        // Two tables share one namespace; a bare "title" would be ambiguous
        // or, worse, silently resolve to the wrong table.
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .where { p, _ in SQLFragment("char_length(\(p.title)) > \(3)") })
        #expect(statement.sql.contains(#"char_length("hangar_posts"."title")"#))
    }
}

// MARK: - Array columns

@Suite("Array columns — SQL")
struct ArrayColumnRendererTests {

    @Test("an entity with array columns renders and binds like any other")
    func insertShape() throws {
        let statement = try SQLRenderer.insert(
            Tagged(name: "a", labels: ["x", "y"], scores: [1, 2]))
        #expect(statement.sql.contains(#""labels""#))
        #expect(statement.sql.contains(#""scores""#))
        // name + labels + scores (id is database-generated)
        #expect(statement.binds.count == 3)
    }
}

// MARK: - Integration

// Sandboxed (testing plan, Phase 3). Two shapes needed scoping, and the bulk
// delete is the more serious of the two: a *write* whose whole assertion is "it
// touched exactly the matching rows". `Post.where { $0.published == false }`
// under `withRepo` meant "the one unpublished row this test made"; in a sandbox
// it means every unpublished post anybody has committed, so `removed` would stop
// being 1. It is now scoped to a fresh owner UUID stamped on all six rows, which
// keeps the predicate (`published == false`) doing the selecting. The array
// read-back is scoped to the two ids it inserted, in the same `id.asc()` order.
extension SandboxedIntegrationSuite {
    @Suite("Phase 0 — bulk delete and array columns (real Postgres, sandboxed)")
    struct Phase0IntegrationTests {

        @Test("bulk delete removes exactly the matching rows and reports the count")
        func bulkDelete() async throws {
            try await withSandbox { repo in
                // One fresh owner across all six rows, so the delete's blast
                // radius is this test's rows and nothing else committed.
                let owner = UUID()
                for i in 1...5 {
                    var keep = Post.sample(title: "keep-\(i)")
                    keep.authorID = owner
                    try await repo.insert(keep)
                }
                var doomed = Post.sample(title: "doomed")
                doomed.published = false
                doomed.authorID = owner
                try await repo.insert(doomed)

                let removed = try await repo.delete(
                    Post.where { $0.authorID == owner && $0.published == false })
                #expect(removed == 1)
                // The five published rows survived — `published == false` is
                // still what decided which row went.
                #expect(try await repo.count(Post.where { $0.authorID == owner }) == 5)

                // Nothing matched: zero is an answer, not an error.
                let none = try await repo.delete(
                    Post.where { $0.authorID == owner && $0.published == false })
                #expect(none == 0)
            }
        }

        @Test("array columns round-trip, including the empty array")
        func arrayRoundTrip() async throws {
            try await withSandbox { repo in
                let stored = try await repo.insert(
                    Tagged(name: "full", labels: ["swift", "postgres"], scores: [7, 11]))
                #expect(stored.labels == ["swift", "postgres"])
                #expect(stored.scores == [7, 11])

                let empty = try await repo.insert(Tagged(name: "empty", labels: [], scores: []))
                #expect(empty.labels.isEmpty)
                #expect(empty.scores.isEmpty)

                // Scoped to the two rows just inserted; ascending id still puts
                // "full" before "empty", so the pair of arrays is unchanged.
                let fetched = try await repo.all(
                    Tagged.where { $0.id.in([stored.id, empty.id]) }.order { $0.id.asc() })
                #expect(fetched.map(\.labels) == [["swift", "postgres"], []])

                // Arrays update like any other column.
                var updated = stored
                updated.labels = ["renamed"]
                let written = try await repo.update(updated)
                #expect(written.labels == ["renamed"])
            }
        }
    }
}

// MARK: - Multi throwing subscript

@Suite("MultiValues — throwing subscript")
struct MultiValuesThrowingTests {

    @Test("a missing key throws, and names the key")
    func missingKeyThrows() throws {
        let values = MultiValues()
        do {
            _ = try values[MultiKey<Int>("absent")]
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("absent"))
        }
    }

    @Test("a same-name key with a different type throws, naming both types")
    func typeMismatchThrows() throws {
        var values = MultiValues()
        values.storage["shared"] = 42
        do {
            _ = try values[MultiKey<String>("shared")]
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("Int"))
            #expect(error.description.contains("String"))
        }
    }
}

// Sandboxed (testing plan, Phase 3). Safe despite being a rollback test: the
// step fails with a client-side `HangarError` (a missing `MultiValues` key), not
// a server error, so the sandbox transaction is never poisoned — and `Multi.run`
// calls `repo.transaction`, which at sandbox depth 1 renders as
// `SAVEPOINT`/`ROLLBACK TO`, so the insert is still genuinely rolled back. The
// rollback proof itself needed scoping: `count(Post.all) == 0` was only ever
// "nothing at all in an empty table". It now counts rows carrying the title the
// rolled-back step tried to write, the same shape `ChangesetIntegrationTests`
// uses, which is a sharper statement of the claim.
extension SandboxedIntegrationSuite {
    @Suite("Multi — step misuse fails the transaction, not the process (sandboxed)")
    struct MultiMisuseIntegrationTests {

        @Test("a step reading an unknown key rolls back and reports through .failure")
        func unknownKeyBecomesStepFailure() async throws {
            try await withSandbox { repo in
                let multi = Multi()
                    .insert(MultiKey<Post>("post"), postChangeset(title: "will roll back"))
                    .run { values in
                        _ = try values[MultiKey<Int>("no-such-step")]
                    }
                switch try await repo.run(multi) {
                case .success:
                    Issue.record("expected the misreading step to fail the Multi")
                case .failure(let failure):
                    #expect(failure.error is HangarError)
                    // The insert before it was rolled back with everything else:
                    // scoped to the title that step tried to write, because a
                    // sandbox sees committed rows from every other suite.
                    #expect(try await repo.count(Post.where { $0.title == "will roll back" }) == 0)
                }
            }
        }
    }
}

// MARK: - Bulk update

@Suite("Bulk update — SQL")
struct BulkUpdateRendererTests {

    @Test("update(query, set:) renders UPDATE ... SET ... WHERE ... RETURNING pk")
    func rendersPredicateUpdate() throws {
        let statement = try SQLRenderer.update(
            Post.where { $0.published == false },
            set: [
                Post.queryColumns.published.set(to: true)._assignment,
                Post.queryColumns.viewCount.set(to: 0)._assignment,
            ])
        #expect(
            statement.sql
                == #"UPDATE "hangar_posts" SET "published" = $1, "view_count" = $2 WHERE ("published" = $3) RETURNING "id""#)
        #expect(statement.binds.count == 3)
    }

    @Test("setting an optional column to nil writes SQL NULL through a bind")
    func nilAssignment() throws {
        let statement = try SQLRenderer.update(
            Post.all,
            set: [Post.queryColumns.nickname.set(to: nil)._assignment])
        #expect(statement.sql == #"UPDATE "hangar_posts" SET "nickname" = $1 RETURNING "id""#)
    }

    @Test("an empty SET throws rather than rendering UPDATE ... SET nothing")
    func emptySetRefused() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(Post.all, set: [])
        }
    }

    @Test("clauses UPDATE cannot honor are refused, same rule as bulk delete")
    func refusesUnsupportedClauses() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(
                Post.all.limit(3),
                set: [Post.queryColumns.published.set(to: true)._assignment])
        }
    }
}

// Sandboxed (testing plan, Phase 3). Both tests are bulk *writes* over
// `Post.where { ... }` / `Post.all`, so scoping is not cosmetic here: unscoped,
// `update(Post.all)` would rewrite every committed post in the table and report
// their count instead of 1, and `update(Post.where { $0.published == false })`
// would report every unpublished row anybody left behind instead of 3. Both are
// now scoped to rows the test created — a fresh owner UUID where the claim is
// about a set of rows and a predicate has to split them, the primary key where
// the test made exactly one row. `one(Post.all)` became `one` by id for the same
// reason: in a sandbox it would have thrown `tooManyRows`.
extension SandboxedIntegrationSuite {
    @Suite("Bulk update (real Postgres, sandboxed)")
    struct BulkUpdateIntegrationTests {

        @Test("one statement writes the matching rows and reports the count")
        func bulkUpdate() async throws {
            try await withSandbox { repo in
                let owner = UUID()
                for i in 1...3 {
                    var draft = Post.sample(title: "draft-\(i)")
                    draft.published = false
                    draft.authorID = owner
                    try await repo.insert(draft)
                }
                var live = Post.sample(title: "already-live")
                live.authorID = owner
                try await repo.insert(live)

                // `published == false` still picks 3 of these 4 rows; the owner
                // only bounds the statement to this test's four.
                let published = try await repo.update(
                    Post.where { $0.authorID == owner && $0.published == false }
                ) {
                    ($0.published.set(to: true), $0.nickname.set(to: "batch"))
                }
                #expect(published == 3)
                #expect(
                    try await repo.count(
                        Post.where { $0.authorID == owner && $0.published == false }) == 0)

                // The already-published row was outside the predicate: untouched.
                let untouched = try await repo.one(Post.where { $0.id == live.id })
                #expect(untouched?.nickname != "batch")

                // Zero matches is an answer, not an error.
                let none = try await repo.update(
                    Post.where { $0.authorID == owner && $0.title == "no-such" }
                ) {
                    ($0.published.set(to: false))
                }
                #expect(none == 0)
            }
        }

        @Test("arity 1: a single assignment needs no tuple ceremony")
        func singleAssignment() async throws {
            try await withSandbox { repo in
                let solo = Post.sample(title: "solo")
                try await repo.insert(solo)
                let count = try await repo.update(Post.where { $0.id == solo.id }) {
                    $0.nickname.set(to: nil)
                }
                #expect(count == 1)
                let row = try await repo.one(Post.where { $0.id == solo.id })
                #expect(row?.nickname == nil)
            }
        }
    }
}

// MARK: - Batch insert

@Suite("Batch insert — SQL")
struct BatchInsertRendererTests {

    @Test("many models render one multi-row VALUES statement")
    func multiRowShape() throws {
        let statement = try SQLRenderer.insert([
            Event(name: "a"), Event(name: "b"), Event(name: "c"),
        ])
        #expect(
            statement.sql
                == #"INSERT INTO "hangar_events" ("name") VALUES ($1), ($2), ($3) RETURNING "id", "name""#)
        #expect(statement.binds.count == 3)
    }
}

// Deliberately NOT sandboxed (testing plan, Phase 3), and this one is not about
// scoping. `batchIsAtomic` provokes a real **server** error — a unique-constraint
// violation — and then keeps querying. Inside an explicit transaction Postgres
// puts the whole transaction into the aborted state after any failed statement
// (SQLSTATE 25P02: "current transaction is aborted, commands ignored until end of
// transaction block"), so the `count(KV.all)` that proves nothing survived the
// batch would not return 1 — it would throw. `repo.insert([models])` is one
// statement with no savepoint around it, so there is nothing to catch the abort.
//
// Wrapping the failing insert in `repo.transaction { }` would make it survivable
// in a sandbox, but it would also change what the test proves: single-*statement*
// atomicity becomes savepoint rollback. `withRepo` is therefore the right home
// for this suite, and `batchInsert` stays with it rather than being split off for
// the sake of one lane.
extension PostgresIntegrationSuite {
    @Suite("Batch insert (real Postgres)")
    struct BatchInsertIntegrationTests {

        @Test("one round trip inserts every row and returns them in input order")
        func batchInsert() async throws {
            try await withRepo { repo in
                let stored = try await repo.insert(
                    (1...5).map { Event(name: "event-\($0)") })
                #expect(stored.map(\.name) == (1...5).map { "event-\($0)" })
                // Database-generated ids were read back, ascending with order.
                #expect(stored.map(\.id) == stored.map(\.id).sorted())
                #expect(try await repo.count(Event.all) == 5)

                // Empty input is a no-op answering [].
                let none = try await repo.insert([Event]())
                #expect(none.isEmpty)
            }
        }

        @Test("a constraint violation inserts nothing — single-statement atomicity")
        func batchIsAtomic() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                await #expect(throws: (any Error).self) {
                    try await repo.insert([
                        KV(key: "fresh", value: "x"),
                        KV(key: "taken", value: "collides"),
                    ])
                }
                // The valid row did not survive its batch-mate's failure.
                #expect(try await repo.count(KV.all) == 1)
            }
        }
    }
}
