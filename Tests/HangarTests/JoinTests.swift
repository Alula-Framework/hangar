import Foundation
import Testing

@testable import Hangar

// Phase 4: joins and correlated subqueries — the
// multi-table scopes where every column renders table-qualified.

@Suite("Joins and correlated subqueries — SQL")
struct JoinRendererTests {

    @Test("inner join selects the base entity's columns, qualified")
    func joinBase() throws {
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id }))
        #expect(statement.sql == #"SELECT "hangar_posts"."id", "hangar_posts"."title", "hangar_posts"."published", "hangar_posts"."view_count", "hangar_posts"."created_at", "hangar_posts"."nickname", "hangar_posts"."status", "hangar_posts"."metadata", "hangar_posts"."author_id" FROM "hangar_posts" JOIN "hangar_comments" ON ("hangar_comments"."post_id" = "hangar_posts"."id")"#)
    }

    @Test("leftJoin + groupBy + select(into:) with an aggregate")
    func designExample() throws {
        struct PostSummary: Decodable, Sendable {
            let id: UUID
            let title: String
            let commentCount: Int
        }
        let statement = try SQLRenderer.select(
            Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
                .groupBy { p, _ in p.id }
                .groupBy { p, _ in p.title }
                .select(into: PostSummary.self) { p, c in
                    (id: p.id, title: p.title, commentCount: c.id.count())
                })
        #expect(statement.sql == #"SELECT "hangar_posts"."id" AS "id", "hangar_posts"."title" AS "title", count("hangar_comments"."id") AS "commentCount" FROM "hangar_posts" LEFT JOIN "hangar_comments" ON ("hangar_comments"."post_id" = "hangar_posts"."id") GROUP BY "hangar_posts"."id", "hangar_posts"."title""#)
    }

    @Test("a composed single-table query carries its clauses into the join")
    func composedIntoJoin() throws {
        let statement = try SQLRenderer.select(
            Post.where { $0.published }
                .limit(5)
                .join(Comment.self, on: { p, c in c.postID == p.id })
                .where { _, c in c.body != "" })
        #expect(statement.sql.contains(#"ON ("hangar_comments"."post_id" = "hangar_posts"."id")"#))
        #expect(statement.sql.contains(#"WHERE ("hangar_posts"."published" AND ("hangar_comments"."body" <> $1))"#))
        #expect(statement.sql.hasSuffix("LIMIT 5"))
    }

    @Test("correlated EXISTS qualifies inner and outer columns")
    func correlatedExists() {
        let statement = SQLRenderer.select(
            Post.where { p in
                Comment.where { $0.postID == p.id && $0.body != "" }.exists()
            })
        #expect(statement.sql.hasSuffix(#"WHERE EXISTS (SELECT 1 FROM "hangar_comments" WHERE (("hangar_comments"."post_id" = "hangar_posts"."id") AND ("hangar_comments"."body" <> $1)))"#))
        #expect(statement.binds.count == 1)
    }

    @Test("an unaliased self-join is still refused — every column would be ambiguous")
    func unaliasedSelfJoin() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.select(Post.join(Post.self, on: { a, b in a.id == b.id }))
        }
        do {
            _ = try SQLRenderer.select(Post.join(Post.self, on: { a, b in a.id == b.id }))
        } catch let error as HangarError {
            // The refusal now names the remedy, not a missing feature.
            #expect(error.description.contains("alias"))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test("an aliased self-join renders both sides distinctly, columns and all")
    func aliasedSelfJoin() throws {
        let statement = try SQLRenderer.select(
            Post.alias("parent").join(
                Post.alias("child"),
                on: { parent, child in child.authorID == parent.authorID }))
        #expect(
            statement.sql
                == #"SELECT "parent"."id", "parent"."title", "parent"."published", "parent"."view_count", "parent"."created_at", "parent"."nickname", "parent"."status", "parent"."metadata", "parent"."author_id" FROM "hangar_posts" AS "parent" JOIN "hangar_posts" AS "child" ON ("child"."author_id" = "parent"."author_id")"#)
    }

    @Test("composition closures after an aliased join see alias-qualified columns")
    func aliasedComposition() throws {
        let statement = try SQLRenderer.select(
            Post.alias("parent").join(Post.alias("child"), on: { p, c in c.authorID == p.authorID })
                .where { parent, child in parent.published && child.title != "x" }
                .order { parent, _ in parent.title.asc() })
        #expect(statement.sql.contains(#"("parent"."published" AND ("child"."title" <> $1))"#))
        #expect(statement.sql.contains(#"ORDER BY "parent"."title" ASC"#))
    }

    @Test("aliasing one side is enough for a self-join")
    func oneSidedAlias() throws {
        let statement = try SQLRenderer.select(
            Post.join(Post.alias("other"), on: { base, other in other.authorID == base.authorID }))
        #expect(statement.sql.contains(#"FROM "hangar_posts" JOIN "hangar_posts" AS "other""#))
    }

    @Test("two sides aliased to the same name are refused")
    func collidingAliases() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.select(
                Post.alias("p").join(Comment.alias("p"), on: { p, c in c.postID == p.id }))
        }
    }

    @Test("an alias on an ordinary two-table join is allowed, not just tolerated")
    func aliasOnPlainJoin() throws {
        let statement = try SQLRenderer.select(
            Post.join(Comment.alias("c"), on: { p, c in c.postID == p.id })
                .where { _, c in c.body != "" })
        #expect(statement.sql.contains(#"JOIN "hangar_comments" AS "c" ON ("c"."post_id" = "hangar_posts"."id")"#))
        #expect(statement.sql.contains(#"("c"."body" <> $1)"#))
    }
}

// Sandboxed (testing plan, Phase 3). Every test here needed scoping: the
// assertions are about whole-table join results, which `withRepo` made
// deterministic by truncating first. A sandbox sees committed rows, and the
// negated-EXISTS case ("posts with no comments") would otherwise match every
// post any other suite left behind. Each query is restricted to the rows the
// test created, which preserves exactly what it was demonstrating.
extension SandboxedIntegrationSuite {
@Suite("Joins (real Postgres, sandboxed)")
struct JoinIntegrationTests {

    @Test("inner join filters base rows; distinct collapses fan-out")
    func innerJoin() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let commented = try await repo.insert(Post.sample(title: "commented"))
            let silent = try await repo.insert(Post.sample(title: "silent"))
            for body in ["one", "two"] {
                try await repo.insert(
                    Comment(id: UUID(), postID: commented.id, authorID: author.id, body: body))
            }

            let mine = [commented.id, silent.id]
            let joined = Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .where { p, _ in p.id.in(mine) }
            // Two comments → the base row fans out twice…
            let fanned = try await repo.all(joined)
            #expect(fanned.map(\.title) == ["commented", "commented"])
            #expect(try await repo.count(joined) == 2)
            // …and DISTINCT collapses it.
            let collapsed = try await repo.all(joined.distinct())
            #expect(collapsed.map(\.title) == ["commented"])
        }
    }

    @Test("end-to-end: comment counts per post, zero included")
    func postSummaries() async throws {
        struct PostSummary: Decodable, Sendable, Equatable {
            let title: String
            let commentCount: Int
        }
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let busy = try await repo.insert(Post.sample(title: "busy"))
            let quiet = try await repo.insert(Post.sample(title: "quiet"))
            for body in ["a", "b", "c"] {
                try await repo.insert(
                    Comment(id: UUID(), postID: busy.id, authorID: author.id, body: body))
            }

            let mine = [busy.id, quiet.id]
            let summaries = try await repo.all(
                Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
                    .where { p, _ in p.id.in(mine) }
                    .groupBy { p, _ in p.id }
                    .groupBy { p, _ in p.title }
                    .order { p, _ in p.title.asc() }
                    .select(into: PostSummary.self) { p, c in
                        (title: p.title, commentCount: c.id.count())
                    })
            #expect(summaries == [
                PostSummary(title: "busy", commentCount: 3),
                PostSummary(title: "quiet", commentCount: 0),
            ])
        }
    }

    @Test("joined pack projection mixes both tables' columns")
    func joinedPackSelect() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let post = try await repo.insert(Post.sample(title: "threaded"))
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: author.id, body: "hello"))

            let rows: [(String, String)] = try await repo.all(
                Post.join(Comment.self, on: { p, c in c.postID == p.id })
                    .where { p, _ in p.id == post.id }
                    .select { p, c in (p.title, c.body) })
            #expect(rows.count == 1)
            #expect(rows[0] == ("threaded", "hello"))
        }
    }

    @Test("correlated EXISTS: posts that have a matching comment")
    func correlatedExists() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let noisy = try await repo.insert(Post.sample(title: "noisy"))
            let quiet = try await repo.insert(Post.sample(title: "silent"))
            try await repo.insert(
                Comment(id: UUID(), postID: noisy.id, authorID: author.id, body: "hi"))

            let mine = [noisy.id, quiet.id]
            let posts = try await repo.all(
                Post.where { p in
                    p.id.in(mine) && Comment.where { $0.postID == p.id }.exists()
                })
            #expect(posts.map(\.title) == ["noisy"])

            // Negated: posts with no comments. Without the id scope this would
            // match every commented-on-nothing post in the database.
            let silent = try await repo.all(
                Post.where { p in
                    p.id.in(mine) && !Comment.where { $0.postID == p.id }.exists()
                })
            #expect(silent.map(\.title) == ["silent"])
        }
    }

    @Test("preloads carry through a join on the base-entity path")
    func joinWithPreload() async throws {
        try await withSandbox { repo in
            let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
            var post = Post.sample(title: "authored")
            post.authorID = ada.id
            try await repo.insert(post)
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: ada.id, body: "hi"))

            let posts = try await repo.all(
                Post.where { $0.id == post.id }.preload(\.author)
                    .join(Comment.self, on: { p, c in c.postID == p.id }))
            #expect(try posts.map { try $0.author.get().name } == ["ada"])
        }
    }
}
}

extension SandboxedIntegrationSuite {
    @Suite("Self-joins (real Postgres, sandboxed)")
    struct SelfJoinIntegrationTests {

        @Test("a self-join answers a real correlated question end to end")
        func coAuthoredPosts() async throws {
            try await withSandbox { repo in
                let shared = UUID()
                var first = Post.sample(title: "first")
                first.authorID = shared
                var second = Post.sample(title: "second")
                second.authorID = shared
                var lone = Post.sample(title: "lone")
                lone.authorID = UUID()
                for post in [first, second, lone] { try await repo.insert(post) }

                // "Posts whose author wrote another, different post."
                struct Pair: Decodable, Sendable {
                    let title: String
                    let sibling: String
                }
                let pairs = try await repo.all(
                    Post.alias("mine").join(
                        Post.alias("sibling"),
                        on: { mine, sibling in sibling.authorID == mine.authorID })
                        .where { mine, sibling in
                            mine.authorID == shared && mine.title != sibling.title
                        }
                        .order { mine, _ in mine.title.asc() }
                        .select(into: Pair.self) { mine, sibling in
                            (title: mine.title, sibling: sibling.title)
                        })
                #expect(pairs.map(\.title) == ["first", "second"])
                #expect(pairs.map(\.sibling) == ["second", "first"])
            }
        }

        @Test("the base-entity path decodes rows fetched under an alias")
        func aliasedBaseEntityFetch() async throws {
            try await withSandbox { repo in
                let shared = UUID()
                for title in ["a", "b"] {
                    var post = Post.sample(title: title)
                    post.authorID = shared
                    try await repo.insert(post)
                }
                let rows = try await repo.all(
                    Post.alias("mine").join(
                        Post.alias("other"),
                        on: { mine, other in other.authorID == mine.authorID })
                        .where { mine, other in
                            mine.authorID == shared && mine.title != other.title
                        })
                #expect(rows.map(\.title).sorted() == ["a", "b"])

                // And count agrees with what all() returned.
                let matches = try await repo.count(
                    Post.alias("mine").join(
                        Post.alias("other"),
                        on: { mine, other in other.authorID == mine.authorID })
                        .where { mine, other in
                            mine.authorID == shared && mine.title != other.title
                        })
                #expect(matches == 2)
            }
        }
    }
}
