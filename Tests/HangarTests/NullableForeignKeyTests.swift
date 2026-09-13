import Foundation
import Testing

@testable import Hangar

/// Optional relationships: a foreign key that may be NULL, on both the
/// association side and the predicate side.
@Suite("Nullable foreign keys")
struct NullableForeignKeyPredicateTests {

    @Test("a nullable column joins against a non-null one")
    func mixedOptionality() throws {
        // `Column<UUID?> == Column<UUID>` — Swift will not unify the two on
        // its own, but SQL draws no such distinction: `=` against NULL yields
        // NULL, which a JOIN reads as "no match". That is exactly what an
        // optional relationship means.
        let statement = try SQLRenderer.select(
            Comment.leftJoin(Author.self, on: { comment, author in
                comment.moderatorID == author.id
            }))
        #expect(
            statement.sql.contains(
                #"ON ("hangar_comments"."moderator_id" = "hangar_authors"."id")"#))
    }

    @Test("the operands commute")
    func reversedOperands() throws {
        let statement = try SQLRenderer.select(
            Comment.leftJoin(Author.self, on: { comment, author in
                author.id == comment.moderatorID
            }))
        #expect(
            statement.sql.contains(
                #"ON ("hangar_authors"."id" = "hangar_comments"."moderator_id")"#))
    }

    @Test("inequality too, in both directions")
    func inequality() throws {
        let left = try SQLRenderer.select(
            Comment.leftJoin(Author.self, on: { comment, author in
                comment.moderatorID != author.id
            }))
        let right = try SQLRenderer.select(
            Comment.leftJoin(Author.self, on: { comment, author in
                author.id != comment.moderatorID
            }))
        #expect(left.sql.contains(#"("hangar_comments"."moderator_id" <> "hangar_authors"."id")"#))
        #expect(right.sql.contains(#"("hangar_authors"."id" <> "hangar_comments"."moderator_id")"#))
    }

    @Test("a self-join over a nullable key renders under both aliases")
    func aliasedSelfJoin() throws {
        let child = Comment.alias("child")
        let parent = Comment.alias("parent")
        let statement = try SQLRenderer.select(
            child.join(parent, on: { child, parent in child.moderatorID == parent.authorID }))
        #expect(statement.sql.contains(#"ON ("child"."moderator_id" = "parent"."author_id")"#))
    }
}

// Sandboxed (testing plan, Phase 3). The orphans test scoped to the two authors
// it creates — it asserted an exact whole-table author list, which only held
// because withRepo truncated first.
extension SandboxedIntegrationSuite {
    @Suite("Has-many over a nullable foreign key (real Postgres, sandboxed)")
    struct NullableHasManyTests {

        @Test("children whose foreign key is NULL belong to no parent")
        func nullChildrenAreOrphans() async throws {
            try await withSandbox { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "Ada"))
                let grace = try await repo.insert(Author(id: UUID(), name: "Grace"))
                let post = try await repo.insert(Post.sample())

                func comment(_ body: String, moderator: UUID?) -> Comment {
                    Comment(
                        id: UUID(), postID: post.id, authorID: ada.id,
                        moderatorID: moderator, body: body)
                }
                _ = try await repo.insert(comment("reviewed by ada", moderator: ada.id))
                _ = try await repo.insert(comment("also ada", moderator: ada.id))
                _ = try await repo.insert(comment("grace's", moderator: grace.id))
                _ = try await repo.insert(comment("unmoderated", moderator: nil))

                let authors = try await repo.all(
                    Author.where { $0.id.in([ada.id, grace.id]) }
                        .order { $0.name.asc() }
                        .preload(\.moderated) { $0.order { $0.body.asc() } })

                #expect(authors.map(\.name) == ["Ada", "Grace"])
                #expect(try authors[0].moderated.get().map(\.body) == ["also ada", "reviewed by ada"])
                #expect(try authors[1].moderated.get().map(\.body) == ["grace's"])
                // The NULL-moderator comment appears under neither author,
                // and no query went looking for a NULL key.
                let all = try authors.flatMap { try $0.moderated.get() }
                #expect(!all.contains { $0.body == "unmoderated" })
            }
        }

        @Test("a parent with no children loads as empty, not as not-loaded")
        func emptyIsLoaded() async throws {
            try await withSandbox { repo in
                let lonely = try await repo.insert(Author(id: UUID(), name: "Lonely"))
                let authors = try await repo.all(
                    Author.where { $0.id == lonely.id }.preload(\.moderated))
                #expect(authors[0].moderated.isLoaded)
                #expect(try authors[0].moderated.get().isEmpty)
            }
        }
    }
}

/// Ordering comparisons against a nullable column.
///
/// The gap these close showed up building a retention job: "purge everything
/// soft-deleted more than thirty days ago" is `deletedAt < cutoff`, the most
/// ordinary query a `@Deleted` column has, and it did not compile. Worse, the
/// near miss made the type checker give up entirely — "failed to produce
/// diagnostic for expression" — so the error named nothing to fix.
@Suite("Ordering comparisons on nullable columns")
struct NullableOrderingTests {

    static let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a nullable timestamp ranges like any other column")
    func lessThan() throws {
        let statement = try SQLRenderer.select(
            StoredFile.all.withDeleted().where { $0.deletedAt < Self.cutoff })

        #expect(statement.sql.contains(#""deleted_at" < $1"#))
        // The bind is the date itself — no NULL literal anywhere, which is
        // what keeps this a range test rather than an always-false one.
        #expect(statement.binds.count == 1)
    }

    @Test("all four orderings render")
    func everyOperator() throws {
        let cases: [(Hangar.Predicate, String)] = [
            (StoredFile.queryColumns.deletedAt < Self.cutoff, "<"),
            (StoredFile.queryColumns.deletedAt > Self.cutoff, ">"),
            (StoredFile.queryColumns.deletedAt <= Self.cutoff, "<="),
            (StoredFile.queryColumns.deletedAt >= Self.cutoff, ">="),
        ]
        for (predicate, symbol) in cases {
            let statement = try SQLRenderer.select(
                StoredFile.all.withDeleted().where { _ in predicate })
            #expect(statement.sql.contains(#""deleted_at" \#(symbol) $1"#))
        }
    }

    @Test("comparing against nil is still IS NULL, not a range")
    func nilIsUnaffected() throws {
        // The ordering overloads take a non-optional right-hand side on
        // purpose, so adding them cannot have changed what `== nil` means.
        let live = try SQLRenderer.select(
            StoredFile.all.withDeleted().where { $0.deletedAt == nil })
        #expect(live.sql.contains(#""deleted_at" IS NULL"#))
        #expect(live.binds.isEmpty)

        let gone = try SQLRenderer.select(
            StoredFile.all.withDeleted().where { $0.deletedAt != nil })
        #expect(gone.sql.contains(#""deleted_at" IS NOT NULL"#))
    }
}
