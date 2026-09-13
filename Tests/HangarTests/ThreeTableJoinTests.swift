import Foundation
import Testing

@testable import Hangar

// MARK: - SQL shapes

@Suite("Three-table joins — SQL")
struct ThreeTableRendererTests {

    @Test("a third join renders FROM a JOIN b ON ... JOIN c ON ..., in order")
    func basicShape() throws {
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .join(Author.self, on: { _, comment, author in comment.authorID == author.id }))
        #expect(
            statement.sql.contains(
                #"FROM "hangar_posts" JOIN "hangar_comments" ON ("hangar_comments"."post_id" = "hangar_posts"."id") JOIN "hangar_authors" ON ("hangar_comments"."author_id" = "hangar_authors"."id")"#
            ))
        // Unprojected: the base entity's qualified list, as with two tables.
        #expect(statement.sql.hasPrefix(#"SELECT "hangar_posts"."id""#))
    }

    @Test("clauses composed before the third join carry through")
    func compositionCarries() throws {
        let statement = try SQLRenderer.select(
            Post.where { $0.published == true }
                .join(Comment.self, on: { p, c in c.postID == p.id })
                .where { _, c in c.body != "" }
                .join(Author.self, on: { _, c, a in c.authorID == a.id })
                .where { _, _, a in a.name != "banned" })
        // All three predicates, AND-combined in composition order —
        // `published == true` is itself a bind, so numbering starts there.
        #expect(statement.sql.contains(#""hangar_posts"."published" = $1"#))
        #expect(statement.sql.contains(#""hangar_comments"."body" <> $2"#))
        #expect(statement.sql.contains(#""hangar_authors"."name" <> $3"#))
    }

    @Test("a mixed inner/left three-table join keeps each join's own kind")
    func mixedKinds() throws {
        let statement = try SQLRenderer.select(
            Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
                .join(Author.self, on: { p, _, a in p.authorID == a.id }))
        #expect(statement.sql.contains(#"LEFT JOIN "hangar_comments""#))
        #expect(statement.sql.contains(#" JOIN "hangar_authors""#))
    }

    @Test("three tables with a repeated name need an alias, and the guard says so")
    func threeWayAmbiguityGuard() throws {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.select(
                Post.join(Comment.self, on: { p, c in c.postID == p.id })
                    .join(Post.self, on: { p, _, other in other.authorID == p.authorID }))
        }
        // Aliased, the same shape renders.
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .join(Post.alias("sibling"), on: { p, _, other in other.authorID == p.authorID }))
        #expect(statement.sql.contains(#"JOIN "hangar_posts" AS "sibling""#))
    }

    @Test("count over a grouped three-table join wraps in a subquery")
    func groupedCount() throws {
        let statement = try SQLRenderer.count(
            Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .join(Author.self, on: { _, c, a in c.authorID == a.id })
                .groupBy { p, _, _ in p.authorID })
        #expect(statement.sql.hasPrefix("SELECT count(*) FROM (SELECT"))
        #expect(statement.sql.contains("GROUP BY"))
    }
}

@Suite("DISTINCT ON — SQL")
struct DistinctOnRendererTests {

    @Test("distinct(on:) renders DISTINCT ON with the named columns")
    func basicShape() {
        let statement = SQLRenderer.select(
            Post.distinct(on: { $0.authorID })
                .order { $0.authorID.asc() }
                .order { $0.createdAt.desc() })
        #expect(statement.sql.hasPrefix(#"SELECT DISTINCT ON ("author_id") "#))
        #expect(statement.sql.contains(#"ORDER BY "author_id" ASC, "created_at" DESC"#))
    }

    @Test("repeated calls accumulate columns")
    func accumulates() {
        let statement = SQLRenderer.select(
            Post.distinct(on: { $0.authorID }).distinct(on: { $0.published }))
        #expect(statement.sql.contains(#"DISTINCT ON ("author_id", "published")"#))
    }

    @Test("distinct() and distinct(on:) are last-call-wins, like limit")
    func lastCallWins() {
        let plain = SQLRenderer.select(Post.distinct(on: { $0.authorID }).distinct())
        #expect(plain.sql.contains("SELECT DISTINCT \""))
        #expect(!plain.sql.contains("DISTINCT ON"))

        let on = SQLRenderer.select(Post.all.distinct().distinct(on: { $0.authorID }))
        #expect(on.sql.contains("DISTINCT ON"))
    }

    @Test("count over DISTINCT ON counts survivors, through a subquery")
    func countWraps() {
        let statement = SQLRenderer.count(Post.distinct(on: { $0.authorID }))
        #expect(statement.sql.hasPrefix("SELECT count(*) FROM (SELECT DISTINCT ON"))
    }

    @Test("bulk writes refuse DISTINCT ON like every other unsupported clause")
    func bulkRefuses() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.distinct(on: { $0.authorID }))
        }
    }

    @Test("a grouped count with no projection projects the grouping — valid SQL now")
    func groupedCountList() {
        let statement = SQLRenderer.count(Post.all.groupBy { $0.authorID })
        #expect(
            statement.sql
                == #"SELECT count(*) FROM (SELECT "author_id" FROM "hangar_posts" GROUP BY "author_id") AS "hangar_count""#)
    }
}

// MARK: - Integration

// Sandboxed (testing plan, Phase 3). All three tests asserted over whole-table
// joins, so each is scoped: the first two to the post they create, the third to
// the two author ids it groups by. Scoping the DISTINCT ON case matters most —
// "newest per author" over every committed post would count other suites' rows
// as groups.
extension SandboxedIntegrationSuite {
    @Suite("Three-table joins and DISTINCT ON (real Postgres, sandboxed)")
    struct ThreeTableIntegrationTests {

        @Test("post → comment → author, projected across all three")
        func endToEnd() async throws {
            try await withSandbox { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                let grace = try await repo.insert(Author(id: UUID(), name: "grace"))
                var post = Post.sample(title: "joined")
                post.authorID = ada.id
                let stored = try await repo.insert(post)
                for (author, body) in [(ada, "self-reply"), (grace, "hi")] {
                    _ = try await repo.insert(
                        Comment(id: UUID(), postID: stored.id, authorID: author.id,
                                moderatorID: nil, body: body))
                }

                struct Row: Decodable, Sendable {
                    let title: String
                    let body: String
                    let commenter: String
                }
                let rows = try await repo.all(
                    Post.join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, c, a in c.authorID == a.id })
                        .where { p, _, _ in p.id == stored.id }
                        .order { _, _, a in a.name.asc() }
                        .select(into: Row.self) { p, c, a in
                            (title: p.title, body: c.body, commenter: a.name)
                        })
                #expect(rows.map(\.commenter) == ["ada", "grace"])
                #expect(rows.map(\.body) == ["self-reply", "hi"])

                // The base-entity path decodes and deduplicates as asked.
                let posts = try await repo.all(
                    Post.join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, c, a in c.authorID == a.id })
                        .where { p, _, _ in p.id == stored.id }
                        .distinct())
                #expect(posts.map(\.title) == ["joined"])

                // count and exists honor the same clauses.
                let matches = try await repo.count(
                    Post.join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, c, a in c.authorID == a.id })
                        .where { p, _, _ in p.id == stored.id })
                #expect(matches == 2)
                let grouped = try await repo.count(
                    Post.join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, c, a in c.authorID == a.id })
                        .where { p, _, _ in p.id == stored.id }
                        .groupBy { _, _, a in a.id })
                #expect(grouped == 2, "two commenter groups, not two matches")
                let any = try await repo.exists(
                    Post.join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, _, a in a.name == "grace" })
                        .where { p, _, _ in p.id == stored.id })
                #expect(any)
            }
        }

        @Test("preloads composed before two joins still run on the base entities")
        func preloadThroughThreeTables() async throws {
            try await withSandbox { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                var post = Post.sample(title: "with-author")
                post.authorID = ada.id
                let stored = try await repo.insert(post)
                _ = try await repo.insert(
                    Comment(id: UUID(), postID: stored.id, authorID: ada.id,
                            moderatorID: nil, body: "note"))

                let posts = try await repo.all(
                    Post.where { $0.id == stored.id }.preload(\.author)
                        .join(Comment.self, on: { p, c in c.postID == p.id })
                        .join(Author.self, on: { _, c, a in c.authorID == a.id }))
                #expect(try posts.map { try $0.author.get().name } == ["ada"])
            }
        }

        @Test("DISTINCT ON answers 'newest per group' end to end")
        func newestPerAuthor() async throws {
            try await withSandbox { repo in
                let first = UUID()
                let second = UUID()
                let mine = [first, second]
                for (author, title, minutesAgo) in [
                    (first, "old-a", 60), (first, "new-a", 1),
                    (second, "old-b", 90), (second, "new-b", 5),
                ] {
                    var post = Post.sample(title: title)
                    post.authorID = author
                    post.createdAt = Date(timeIntervalSinceNow: -Double(minutesAgo) * 60)
                    try await repo.insert(post)
                }
                let newest = try await repo.all(
                    Post.where { $0.authorID.in(mine) }
                        .distinct(on: { $0.authorID })
                        .order { $0.authorID.asc() }
                        .order { $0.createdAt.desc() })
                #expect(newest.count == 2)
                #expect(Set(newest.map(\.title)) == ["new-a", "new-b"])

                // ...and count counts groups, not rows.
                #expect(
                    try await repo.count(
                        Post.where { $0.authorID.in(mine) }.distinct(on: { $0.authorID })) == 2)
                #expect(
                    try await repo.count(
                        Post.where { $0.authorID.in(mine) }.groupBy { $0.authorID }) == 2)
            }
        }
    }
}
