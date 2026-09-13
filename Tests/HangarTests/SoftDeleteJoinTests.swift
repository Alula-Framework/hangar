import Foundation
import Testing

@testable import Hangar

/// Soft deletion across joins.
///
/// `Query` had this right from the start — `effectivePredicate` puts the
/// scope condition on every read path. Every *join* form dropped it: the
/// conversion carried `predicate`, `grouping`, `rowLock`, even `preloads`,
/// and left the deleted-row scope behind. `StoredFile.onlyDeleted().join(…)`
/// was the worst of it — an explicit request for deleted rows only, silently
/// answered with all of them.
///
/// The rule these tests pin, in one sentence: the scope applies to the base
/// source in `WHERE`, every joined soft-deletable source excludes its own
/// deleted rows in `ON`, and `withDeleted()` lifts both.
@Suite("Soft delete × joins — SQL")
struct SoftDeleteJoinRendererTests {

    // MARK: Two-table

    @Test("a join keeps the base entity's exclusion, exactly as the single-table read does")
    func baseScopeSurvivesTheJoin() {
        let single = StoredFile.where { $0.name != "x" }.debugSQL
        #expect(single.contains(#"("deleted_at" IS NULL)"#))

        let joined = StoredFile.where { $0.name != "x" }
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .debugSQL
        #expect(
            joined.contains(
                #"WHERE (("hangar_files"."name" <> $1) AND ("hangar_files"."deleted_at" IS NULL))"#))
    }

    @Test("onlyDeleted() survives the join instead of inverting into no filter at all")
    func onlyDeletedSurvivesTheJoin() {
        let sql = StoredFile.onlyDeleted()
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .debugSQL
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NOT NULL)"#))
    }

    @Test("withDeleted() lifts the condition everywhere in the statement")
    func withDeletedLiftsIt() {
        let sql = StoredFile.all.withDeleted()
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .debugSQL
        // The column stays in the SELECT list — it is one of the entity's
        // own; what must be gone is any condition over it.
        #expect(!sql.contains(#""deleted_at" IS"#))
    }

    @Test("the scope can also be set on the join itself, not only before it")
    func scopeOnTheJoinValue() {
        let sql = StoredFile.join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .onlyDeleted()
            .debugSQL
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NOT NULL)"#))
    }

    @Test("a soft-deletable *joined* table is scoped in ON, so a LEFT JOIN stays outer")
    func joinedSideScopedInOn() {
        let inner = Author.join(StoredFile.self, on: { owner, file in file.ownerID == owner.id })
            .debugSQL
        #expect(
            inner.contains(
                #"ON (("hangar_files"."owner_id" = "hangar_authors"."id") AND ("hangar_files"."deleted_at" IS NULL))"#
            ))
        // Nothing landed in WHERE: there is no WHERE at all here.
        #expect(!inner.contains("WHERE"))

        let outer = Author.leftJoin(StoredFile.self, on: { owner, file in file.ownerID == owner.id })
            .debugSQL
        #expect(outer.contains("LEFT JOIN"))
        #expect(outer.contains(#"AND ("hangar_files"."deleted_at" IS NULL))"#))
        #expect(!outer.contains("WHERE"))
    }

    @Test("onlyDeleted() on the base still joins to live rows on the other side")
    func onlyDeletedScopesTheBaseAlone() {
        // Base and joined side are both soft-deletable here, so the two
        // conditions must differ: the base is the trash view, the joined
        // side is not.
        let sql = StoredFile.onlyDeleted()
            .join(StoredFile.alias("other"), on: { file, other in other.ownerID == file.ownerID })
            .debugSQL
        #expect(sql.contains(#"AND ("other"."deleted_at" IS NULL))"#))
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NOT NULL)"#))
    }

    @Test("an aliased base is scoped under its alias, not its table name")
    func aliasedBaseScope() {
        let sql = StoredFile.alias("f")
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .debugSQL
        #expect(sql.contains(#"WHERE ("f"."deleted_at" IS NULL)"#))
    }

    @Test("count and exists carry the scope too, not just select")
    func countAndExistsCarryTheScope() throws {
        let query = StoredFile.join(Author.self, on: { file, owner in owner.id == file.ownerID })
        let count = try SQLRenderer.count(query).sql
        let exists = try SQLRenderer.exists(query).sql
        #expect(count.contains(#"WHERE ("hangar_files"."deleted_at" IS NULL)"#))
        #expect(exists.contains(#"WHERE ("hangar_files"."deleted_at" IS NULL)"#))
    }

    @Test("a projection over the join keeps the scope the projection was asked for")
    func projectionKeepsTheScope() {
        struct Row: Decodable, Sendable {
            let name: String
            let owner: String
        }
        let sql = StoredFile.onlyDeleted()
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .select(into: Row.self) { file, owner in (name: file.name, owner: owner.name) }
            .debugSQL
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NOT NULL)"#))
    }

    // MARK: Three-table

    @Test("a three-table join scopes the base and both joined sides")
    func threeTableScope() {
        let sql = StoredFile.join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .join(Profile.self, on: { _, owner, profile in profile.authorID == owner.id })
            .debugSQL
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NULL)"#))

        // The soft-deletable table in the *third* position is scoped in its
        // own ON clause.
        let third = Author.join(Profile.self, on: { owner, profile in profile.authorID == owner.id })
            .join(StoredFile.self, on: { owner, _, file in file.ownerID == owner.id })
            .debugSQL
        #expect(
            third.contains(
                #"ON (("hangar_files"."owner_id" = "hangar_authors"."id") AND ("hangar_files"."deleted_at" IS NULL))"#
            ))
        #expect(!third.contains("WHERE"))
    }

    @Test("the scope composed before the third join carries through it")
    func threeTableScopeComposesForward() {
        let sql = StoredFile.onlyDeleted()
            .join(Author.self, on: { file, owner in owner.id == file.ownerID })
            .join(Profile.self, on: { _, owner, profile in profile.authorID == owner.id })
            .debugSQL
        #expect(sql.contains(#"WHERE ("hangar_files"."deleted_at" IS NOT NULL)"#))
    }

    @Test("withDeleted() on a three-table join lifts every condition")
    func threeTableWithDeleted() {
        let sql = Author.join(Profile.self, on: { owner, profile in profile.authorID == owner.id })
            .join(StoredFile.self, on: { owner, _, file in file.ownerID == owner.id })
            .withDeleted()
            .debugSQL
        #expect(!sql.contains(#""deleted_at" IS"#))
    }

    // MARK: Composed (Table.query { })

    @Test("a composed query scopes its base in WHERE and its joins in ON")
    func composedScope() {
        let baseScoped = StoredFile.query { q, file in
            _ = q.join(Author.self) { $0.id == file.ownerID }
            return q.query()
        }
        #expect(baseScoped.debugSQL.contains(#"WHERE ("t0"."deleted_at" IS NULL)"#))

        let joinScoped = Author.query { q, owner in
            _ = q.join(StoredFile.self) { $0.ownerID == owner.id }
            return q.query()
        }
        #expect(
            joinScoped.debugSQL.contains(
                #"ON (("t1"."owner_id" = "t0"."id") AND ("t1"."deleted_at" IS NULL))"#))
        #expect(!joinScoped.debugSQL.contains("WHERE"))
    }

    @Test("a composed query's scope operators behave like every other form's")
    func composedScopeOperators() {
        let only = StoredFile.query { q, file in
            _ = q.join(Author.self) { $0.id == file.ownerID }
            q.onlyDeleted()
            return q.query()
        }
        #expect(only.debugSQL.contains(#"WHERE ("t0"."deleted_at" IS NOT NULL)"#))

        let everything = Author.query { q, owner in
            _ = q.leftJoin(StoredFile.self) { $0.ownerID == owner.id }
            q.withDeleted()
            return q.query()
        }
        #expect(!everything.debugSQL.contains(#""deleted_at" IS"#))
    }

    @Test("composed count and exists carry the scope")
    func composedCountCarriesTheScope() {
        let query = StoredFile.query { q, file in
            _ = q.join(Author.self) { $0.id == file.ownerID }
            return q.query()
        }
        #expect(SQLRenderer.count(query).sql.contains(#"WHERE ("t0"."deleted_at" IS NULL)"#))
        #expect(SQLRenderer.exists(query).sql.contains(#"WHERE ("t0"."deleted_at" IS NULL)"#))
    }

    @Test("a model with no @Deleted column gets no condition anywhere")
    func nonSoftDeletableIsUntouched() {
        let sql = Post.join(Comment.self, on: { post, comment in comment.postID == post.id })
            .debugSQL
        #expect(!sql.contains("deleted_at"))
    }
}

// MARK: - Integration

// Sandboxed (testing plan, Phase 3). The renderer suite above is untouched: it
// asserts on generated SQL and never opens a connection.
//
// What needed scoping: these tests assert on *which* rows a join returns, and
// every one of them used to lean on `withRepo` having truncated `hangar_files`
// and `hangar_authors` first — `repo.all(StoredFile.all)`, `rows.count == 2`,
// `owners.count == 2`. A sandbox sees every committed row, so each query is now
// restricted to the seeded fixtures:
//
// - base-side (`StoredFile` first) joins take `.where { file, _ in
//   file.ownerID == seeded.owner.id }`, so *both* seeded files remain in range
//   and only the deleted-row scope may drop one — the property under test.
// - joined-side (`Author` first) joins take `.where { owner, _ in
//   owner.id.in([...]) }` over the two authors the test creates, which keeps the
//   LEFT-vs-INNER distinction observable: the point is whether the childless
//   owner survives, so it must be inside the scope, not outside it.
// - composed queries get the same condition through `q.where(...)`.
extension SandboxedIntegrationSuite {
    @Suite("Soft delete × joins (real Postgres, sandboxed)")
    struct SoftDeleteJoinIntegrationTests {

        /// One owner, one live file, one deleted file.
        private func seed(_ repo: Repo) async throws -> (owner: Author, live: StoredFile, gone: StoredFile) {
            let owner = try await repo.insert(Author(id: UUID(), name: "owner"))
            let live = try await repo.insert(
                StoredFile(id: UUID(), name: "keep.txt", sizeBytes: 10, ownerID: owner.id, deletedAt: nil))
            let gone = try await repo.insert(
                StoredFile(id: UUID(), name: "bin.txt", sizeBytes: 20, ownerID: owner.id, deletedAt: nil))
            try await repo.delete(gone)
            return (owner, live, gone)
        }

        @Test("a join returns the same rows the equivalent single-table read does")
        func joinMatchesSingleTable() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                let mine = seeded.owner.id

                let single = try await repo.all(StoredFile.where { $0.ownerID == mine })
                let joined = try await repo.all(
                    StoredFile.join(Author.self, on: { file, owner in owner.id == file.ownerID })
                        .where { file, _ in file.ownerID == mine })
                #expect(single.map(\.id) == [seeded.live.id])
                #expect(joined.map(\.id) == [seeded.live.id])
                #expect(try await repo.count(
                    StoredFile.join(Author.self, on: { file, owner in owner.id == file.ownerID })
                        .where { file, _ in file.ownerID == mine }) == 1)
            }
        }

        @Test("onlyDeleted() through a join returns the deleted row, not every row")
        func onlyDeletedThroughAJoin() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                let mine = seeded.owner.id
                // Both of this owner's files are in range; only the trash view
                // may narrow it to one, which is what the name claims.
                let rows = try await repo.all(
                    StoredFile.onlyDeleted()
                        .join(Author.self, on: { file, owner in owner.id == file.ownerID })
                        .where { file, _ in file.ownerID == mine })
                #expect(rows.map(\.id) == [seeded.gone.id])
            }
        }

        @Test("withDeleted() through a join returns both")
        func withDeletedThroughAJoin() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                let mine = seeded.owner.id
                let rows = try await repo.all(
                    StoredFile.all.withDeleted()
                        .join(Author.self, on: { file, owner in owner.id == file.ownerID })
                        .where { file, _ in file.ownerID == mine })
                #expect(rows.count == 2)
                #expect(Set(rows.map(\.id)) == Set([seeded.live.id, seeded.gone.id]))
            }
        }

        @Test("a LEFT JOIN to a soft-deletable table keeps parents whose only child is deleted")
        func leftJoinStaysOuter() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                // A second owner whose only file is deleted: with the scope
                // in WHERE rather than ON this row would vanish, which is
                // the outer join silently becoming an inner one.
                let lonely = try await repo.insert(Author(id: UUID(), name: "lonely"))
                let onlyFile = try await repo.insert(
                    StoredFile(id: UUID(), name: "gone.txt", sizeBytes: 1, ownerID: lonely.id, deletedAt: nil))
                try await repo.delete(onlyFile)

                // Scoped to the two authors this test created — and the lonely
                // one is inside that scope, so "he survives the outer join"
                // remains exactly what the count proves.
                let authors = [seeded.owner.id, lonely.id]
                let owners = try await repo.all(
                    Author.leftJoin(StoredFile.self, on: { owner, file in file.ownerID == owner.id })
                        .where { owner, _ in owner.id.in(authors) }
                        .distinct())
                #expect(owners.contains { $0.id == lonely.id })
                #expect(owners.count == 2)
            }
        }

        @Test("an inner join to a soft-deletable table does not match its deleted rows")
        func innerJoinSkipsDeletedChildren() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                let lonely = try await repo.insert(Author(id: UUID(), name: "lonely"))
                let onlyFile = try await repo.insert(
                    StoredFile(id: UUID(), name: "gone.txt", sizeBytes: 1, ownerID: lonely.id, deletedAt: nil))
                try await repo.delete(onlyFile)

                let authors = [seeded.owner.id, lonely.id]
                let owners = try await repo.all(
                    Author.join(StoredFile.self, on: { owner, file in file.ownerID == owner.id })
                        .where { owner, _ in owner.id.in(authors) })
                #expect(owners.allSatisfy { $0.id != lonely.id })
                // The owner with a live file must still come back: otherwise an
                // inner join that matched nothing at all would satisfy the
                // assertion above vacuously.
                #expect(owners.contains { $0.id == seeded.owner.id })
            }
        }

        @Test("a composed query honours the scope on both sides")
        func composedHonoursTheScope() async throws {
            try await withSandbox { repo in
                let seeded = try await seed(repo)
                let mine = seeded.owner.id

                let live = try await repo.all(
                    StoredFile.query { q, file in
                        _ = q.join(Author.self) { $0.id == file.ownerID }
                        q.where(file.ownerID == mine)
                        return q.query()
                    })
                #expect(live.map(\.id) == [seeded.live.id])

                let trash = try await repo.all(
                    StoredFile.query { q, file in
                        _ = q.join(Author.self) { $0.id == file.ownerID }
                        q.where(file.ownerID == mine)
                        q.onlyDeleted()
                        return q.query()
                    })
                #expect(trash.map(\.id) == [seeded.gone.id])

                // Scoped to the seeded author, whose two files are one live and
                // one deleted: the count is 1 only because the joined side
                // excludes its own deleted rows — dropping that scope makes it 2.
                let counted = try await repo.count(
                    Author.query { q, owner in
                        _ = q.join(StoredFile.self) { $0.ownerID == owner.id }
                        q.where(owner.id == mine)
                        return q.query()
                    })
                #expect(counted == 1, "only the live file matches")
            }
        }
    }
}
