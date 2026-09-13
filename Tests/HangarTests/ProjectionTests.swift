import Foundation
import Testing

@testable import Hangar

// Phase 4: projections, aggregates, subqueries, upsert.
// The unit suite pins SQL text; the integration suite proves decode.

@Suite("Projections and aggregates — SQL")
struct ProjectionRendererTests {

    @Test("select single column — the pack signature at arity 1")
    func selectSingle() {
        let statement = SQLRenderer.select(Post.select { $0.id })
        #expect(statement.sql == #"SELECT "id" FROM "hangar_posts""#)
    }

    @Test("select tuple keeps written order and composes with where")
    func selectTuple() {
        let statement = SQLRenderer.select(
            Post.where { $0.published }.select { ($0.id, $0.title, $0.viewCount) })
        #expect(statement.sql == #"SELECT "id", "title", "view_count" FROM "hangar_posts" WHERE "published""#)
    }

    @Test("aggregates render with their dialect casts (NUMERIC never reaches the decoder)")
    func aggregateCasts() {
        let statement = SQLRenderer.select(
            Post.select { ($0.id.count(), $0.viewCount.sum(), $0.viewCount.avg(), $0.createdAt.max()) })
        #expect(statement.sql == #"SELECT count("id"), (sum("view_count"))::bigint, (avg("view_count"))::float8, max("created_at") FROM "hangar_posts""#)
    }

    @Test("groupBy + having render after WHERE, with bound aggregate comparisons")
    func groupByHaving() {
        let statement = SQLRenderer.select(
            Post.where { $0.published }
                .groupBy { $0.authorID }
                .having { $0.viewCount.sum() > 100 }
                .select { ($0.authorID, $0.id.count()) })
        #expect(statement.sql == #"SELECT "author_id", count("id") FROM "hangar_posts" WHERE "published" GROUP BY "author_id" HAVING ((sum("view_count"))::bigint > $1)"#)
        #expect(statement.binds.count == 1)
    }

    @Test("select(into:) aliases every column from the tuple labels")
    func selectIntoAliases() {
        struct AuthorCount: Decodable, Sendable {
            let author: UUID
            let posts: Int
        }
        let statement = SQLRenderer.select(
            Post.groupBy { $0.authorID }
                .select(into: AuthorCount.self) { (author: $0.authorID, posts: $0.id.count()) })
        #expect(statement.sql == #"SELECT "author_id" AS "author", count("id") AS "posts" FROM "hangar_posts" GROUP BY "author_id""#)
    }

    @Test("a select(into:) tuple without labels is refused before the wire")
    func selectIntoUnlabeled() async {
        struct Pair: Decodable, Sendable {
            let a: UUID
            let b: String
        }
        let query = Post.select(into: Pair.self) { ($0.id, $0.title) }
        #expect(query.selection?.invalid != nil)
    }

    @Test("distinct")
    func distinct() {
        let statement = SQLRenderer.select(Post.select { $0.authorID }.distinct())
        #expect(statement.sql == #"SELECT DISTINCT "author_id" FROM "hangar_posts""#)
    }

    @Test("IN over a value list is one bound array")
    func inValues() {
        let statement = SQLRenderer.select(Post.where { $0.viewCount.in([1, 2, 3]) })
        #expect(statement.sql.hasSuffix(#"WHERE ("view_count" = ANY($1))"#))
        #expect(statement.binds.count == 1)
    }

    @Test("IN over a subquery shares the outer statement's placeholder numbering")
    func inSubquery() {
        let famous = Author.where { $0.name != "nobody" }.select { $0.id }
        let statement = SQLRenderer.select(
            Post.where { $0.published && $0.authorID.in(famous) && $0.viewCount > 10 })
        #expect(statement.sql == #"SELECT "id", "title", "published", "view_count", "created_at", "nickname", "status", "metadata", "author_id" FROM "hangar_posts" WHERE (("published" AND ("author_id" IN (SELECT "id" FROM "hangar_authors" WHERE ("name" <> $1)))) AND ("view_count" > $2))"#)
        #expect(statement.binds.count == 2)
    }
}

@Suite("Upsert — ON CONFLICT")
struct UpsertRendererTests {

    @Test("doUpdate renders target and EXCLUDED assignments")
    func doUpdate() throws {
        let changeset = Changeset(KV.self).change(\.key, "k").change(\.value, "v")
        let statement = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self,
            onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
        #expect(statement.sql == """
            INSERT INTO "hangar_kv" ("key", "value") VALUES ($1, $2) \
            ON CONFLICT ("key") DO UPDATE SET "value" = EXCLUDED."value" \
            RETURNING "id", "key", "value"
            """)
    }

    @Test("doNothing renders bare and targeted forms")
    func doNothing() throws {
        let changeset = Changeset(KV.self).change(\.key, "k").change(\.value, "v")
        let bare = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self, onConflict: .doNothing)
        #expect(bare.sql.contains("ON CONFLICT DO NOTHING"))
        let targeted = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self,
            onConflict: .doNothing(target: [\KV.key]))
        #expect(targeted.sql.contains(#"ON CONFLICT ("key") DO NOTHING"#))
    }

    @Test("a non-column keypath in the conflict clause throws")
    func badKeyPath() throws {
        let changeset = Changeset(KV.self).change(\.key, "k")
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.insert(
                try changeset.validatedChanges(), into: KV.self,
                onConflict: .doUpdate(target: [\KV.self], set: [\KV.value]))
        }
    }
}

// Sandboxed (testing plan, Phase 3). This suite was the most truncation-dependent
// of the lot: almost every assertion is an aggregate or a projection over
// `Post.all`/`KV.all` compared to an exact value, which is only "the rows this
// test inserted" while `withRepo` wipes the table first. A sandbox truncates
// nothing and sees every committed row, so:
//
// - every post-backed test now seeds its rows under one freshly generated
//   `authorID` and scopes its queries to that owner. GROUP BY is the sharpest
//   case: an unscoped `groupBy { $0.authorID }` returns one row *per author in
//   the table*, so `totals.count == 1` and the `select(into:)` equality were both
//   at the mercy of whatever else had committed.
// - the two upsert tests use a unique conflict key. `hangar_kv.key` is UNIQUE and
//   `TransactionFeatureTests`/`Phase0Tests` leave committed rows behind, so a
//   hardcoded "color" could collide with a *pre-existing* row and make the first
//   insert update that instead of inserting — a different test entirely.
//
// Every scope is a strict addition to the predicate under test; the rows that
// each assertion was distinguishing between are all still in scope, so nothing
// here became vacuous. (Generated `KV.id` values are never asserted absolutely,
// only compared to each other, which rollback-unsafe sequences still permit.)
extension SandboxedIntegrationSuite {
@Suite("Projections, aggregates, upsert (real Postgres, sandboxed)")
struct ProjectionIntegrationTests {

    @Test("single-column and tuple projections decode typed")
    func typedProjections() async throws {
        try await withSandbox { repo in
            // One owner for both rows, so "the published one" and "both, ordered
            // by views" can be asked without the rest of the table joining in.
            let owner = UUID()
            var published = Post.sample(title: "projected", viewCount: 7)
            published.authorID = owner
            var unpublished = Post.sample(title: "other", published: false, viewCount: 3)
            unpublished.authorID = owner
            let post = try await repo.insert(published)
            _ = try await repo.insert(unpublished)

            let ids: [UUID] = try await repo.all(
                Post.where { $0.authorID == owner && $0.published }.select { $0.id })
            #expect(ids == [post.id])

            let rows: [(UUID, String, Int)] = try await repo.all(
                Post.where { $0.authorID == owner }
                    .order { $0.viewCount.desc() }
                    .select { ($0.id, $0.title, $0.viewCount) })
            #expect(rows.map(\.1) == ["projected", "other"])
            #expect(rows.map(\.2) == [7, 3])

            let pair = try await repo.one(
                Post.where { $0.authorID == owner && $0.title == "projected" }
                    .select { ($0.title, $0.nickname) })
            #expect(pair?.0 == "projected")
            #expect(pair?.1 == nil)
        }
    }

    @Test("aggregates: count/sum/avg/min/max, with groupBy and having")
    func aggregates() async throws {
        try await withSandbox { repo in
            let prolific = UUID()
            let quiet = UUID()
            for (author, views) in [(prolific, 10), (prolific, 30), (quiet, 5)] {
                var post = Post.sample(title: "v\(views)", viewCount: views)
                post.authorID = author
                try await repo.insert(post)
            }

            // Restricted to the two authors this test created, so GROUP BY yields
            // exactly their two groups. HAVING still has to drop `quiet` (sum 5)
            // for `totals.count == 1` to hold, which is the claim.
            let mine = Post.where { $0.authorID.in([prolific, quiet]) }
            let totals = try await repo.all(
                mine.groupBy { $0.authorID }
                    .having { $0.viewCount.sum() > 20 }
                    .select { ($0.authorID, $0.id.count(), $0.viewCount.sum(), $0.viewCount.avg()) })
            #expect(totals.count == 1)
            #expect(totals[0].0 == prolific)
            #expect(totals[0].1 == 2)
            #expect(totals[0].2 == 40)
            #expect(totals[0].3 == 20.0)

            // min/max over the same three rows: 5 and 30 are the extremes of
            // this test's data, not of the table.
            let bounds = try await repo.one(mine.select { ($0.viewCount.min(), $0.viewCount.max()) })
            #expect(bounds?.0 == 5)
            #expect(bounds?.1 == 30)

            // Aggregates over zero rows are NULL — hence the optionals. Still
            // zero rows, and now provably so: no committed post can be both this
            // test's author and titled "missing".
            let empty = try await repo.one(
                mine.where { $0.title == "missing" }
                    .select { ($0.viewCount.sum(), $0.viewCount.avg()) })
            #expect(empty?.0 == nil)
            #expect(empty?.1 == nil)
        }
    }

    @Test("select(into:) decodes a named Decodable type by alias")
    func selectInto() async throws {
        struct AuthorSummary: Decodable, Sendable, Equatable {
            let author: UUID
            let posts: Int
            let topTitle: String?
        }
        try await withSandbox { repo in
            let author = UUID()
            for title in ["alpha", "omega"] {
                var post = Post.sample(title: title)
                post.authorID = author
                try await repo.insert(post)
            }
            // Scoped to this author, so the grouped result is exactly one row —
            // the equality against a single-element array is the assertion, and
            // unscoped it would pick up a group per committed author.
            let summaries = try await repo.all(
                Post.where { $0.authorID == author }
                    .groupBy { $0.authorID }
                    .select(into: AuthorSummary.self) {
                        (author: $0.authorID, posts: $0.id.count(), topTitle: $0.title.max())
                    })
            #expect(summaries == [AuthorSummary(author: author, posts: 2, topTitle: "omega")])
        }
    }

    @Test("distinct and IN-list")
    func distinctAndInList() async throws {
        try await withSandbox { repo in
            let shared = UUID()
            for title in ["a", "b"] {
                var post = Post.sample(title: title)
                post.authorID = shared
                try await repo.insert(post)
            }
            // Two rows share one author; DISTINCT still has to collapse them to
            // one, or this reads [shared, shared] and fails.
            let authors: [UUID] = try await repo.all(
                Post.where { $0.authorID == shared }.select { $0.authorID }.distinct())
            #expect(authors == [shared])

            // The IN list still does the filtering — "b" is in scope and excluded,
            // "zzz" matches nothing — the owner scope only keeps other suites'
            // rows titled "a" out of it.
            let titles: [String] = try await repo.all(
                Post.where { $0.authorID == shared && $0.title.in(["a", "zzz"]) }
                    .select { $0.title })
            #expect(titles == ["a"])
        }
    }

    @Test("IN subquery: posts by authors selected in a nested query")
    func inSubquery() async throws {
        try await withSandbox { repo in
            // Unique names: the inner subquery selects "authors named X", and
            // "ada" is a name other suites commit too — a stray committed ada
            // would widen the subquery's result and pull in her posts.
            let adaName = "ada-\(UUID().uuidString)"
            let ada = try await repo.insert(Author(id: UUID(), name: adaName))
            let ghost = try await repo.insert(Author(id: UUID(), name: "ghost-\(UUID().uuidString)"))
            var kept = Post.sample(title: "kept")
            kept.authorID = ada.id
            var dropped = Post.sample(title: "dropped")
            dropped.authorID = ghost.id
            try await repo.insert(kept)
            try await repo.insert(dropped)

            let adaIDs = Author.where { $0.name == adaName }.select { $0.id }
            // Both of this test's posts are in scope, so the subquery is what
            // has to exclude `dropped`.
            let posts = try await repo.all(
                Post.where { $0.id.in([kept.id, dropped.id]) && $0.authorID.in(adaIDs) })
            #expect(posts.map(\.title) == ["kept"])
        }
    }

    @Test("upsert doUpdate: second insert updates only the set columns")
    func upsertDoUpdate() async throws {
        try await withSandbox { repo in
            // A key of this test's own, so the conflict is between the two
            // inserts below and not with some row committed earlier.
            let key = "color-\(UUID().uuidString)"
            let first = try await repo.insert(
                Changeset(KV.self).change(\.key, key).change(\.value, "red"),
                onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
            let second = try await repo.insert(
                Changeset(KV.self).change(\.key, key).change(\.value, "blue"),
                onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
            #expect(first?.value == "red")
            #expect(second?.value == "blue")
            #expect(second?.id == first?.id)  // same row, updated
            let count = try await repo.count(KV.where { $0.key == key })
            #expect(count == 1)
        }
    }

    @Test("upsert doNothing: the conflicting insert is skipped and returns nil")
    func upsertDoNothing() async throws {
        try await withSandbox { repo in
            let key = "color-\(UUID().uuidString)"
            let first = try await repo.insert(
                Changeset(KV.self).change(\.key, key).change(\.value, "red"),
                onConflict: .doNothing)
            let skipped = try await repo.insert(
                Changeset(KV.self).change(\.key, key).change(\.value, "blue"),
                onConflict: .doNothing)
            #expect(first != nil)
            #expect(skipped == nil)
            // The surviving row still holds the *first* value: DO NOTHING must
            // not have overwritten it with "blue".
            let values: [String] = try await repo.all(
                KV.where { $0.key == key }.select { $0.value })
            #expect(values == ["red"])
        }
    }
}
}
