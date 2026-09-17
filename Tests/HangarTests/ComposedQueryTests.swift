import Foundation
import Testing

@testable import Hangar

// MARK: - SQL shapes

@Suite("Composed queries (Table.query { }) — SQL")
struct ComposedQueryRendererTests {

    @Test("four joins render FROM/JOIN in order, every alias fresh and distinct")
    func fourTableShape() {
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            let author = q.join(Author.self) { $0.id == comment.authorID }
            _ = q.join(Profile.self) { $0.authorID == author.id }
            return q.query()
        }
        let sql = query.debugSQL
        #expect(
            sql.contains(
                #"FROM "hangar_posts" AS "t0" JOIN "hangar_comments" AS "t1" ON ("t1"."post_id" = "t0"."id") JOIN "hangar_authors" AS "t2" ON ("t2"."id" = "t1"."author_id") JOIN "hangar_profiles" AS "t3" ON ("t3"."author_id" = "t2"."id")"#
            ))
        // Unprojected: the base entity's own columns, qualified with its alias.
        #expect(sql.hasPrefix(#"SELECT "t0"."id""#))
    }

    @Test("where() combines conditions from different joined tables under one AND")
    func crossTableWhere() {
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            let author = q.join(Author.self) { $0.id == comment.authorID }
            q.where(comment.body != "" && author.name != "banned")
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"WHERE (("t1"."body" <> $1) AND ("t2"."name" <> $2))"#))
    }

    @Test("a self-join needs no .alias(_:) at all — every join alias is fresh by construction")
    func selfJoinNeedsNoManualAlias() {
        // Post joined back to itself twice, plus a third distinct table —
        // exactly the case JoinedQuery/JoinedQuery3 need an explicit
        // `.alias("name")` for. Here it just works: t0/t1/t2 never collide.
        let query = Post.query { q, post in
            let sibling = q.join(Post.self) { $0.authorID == post.authorID }
            _ = q.join(Author.self) { $0.id == post.authorID }
            q.where(sibling.id != post.id)
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"FROM "hangar_posts" AS "t0" JOIN "hangar_posts" AS "t1""#))
        #expect(sql.contains(#"JOIN "hangar_authors" AS "t2""#))
        #expect(sql.contains(#"WHERE ("t1"."id" <> "t0"."id")"#))
    }

    @Test("leftJoin renders LEFT JOIN, inner joins in the same query stay JOIN")
    func mixedJoinKinds() {
        let query = Post.query { q, post in
            _ = q.leftJoin(Comment.self) { $0.postID == post.id }
            _ = q.join(Author.self) { $0.id == post.authorID }
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"LEFT JOIN "hangar_comments""#))
        #expect(sql.contains(#" JOIN "hangar_authors""#))
    }

    @Test("select(into:) projects labeled columns from every joined table")
    func projectionAcrossFourTables() {
        struct Row: Decodable, Sendable {
            let title: String
            let body: String
            let author: String
            let bio: String
        }
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            let author = q.join(Author.self) { $0.id == comment.authorID }
            let profile = q.join(Profile.self) { $0.authorID == author.id }
            return q.select(into: Row.self) {
                (title: post.title, body: comment.body, author: author.name, bio: profile.bio)
            }
        }
        let sql = query.debugSQL
        #expect(
            sql.hasPrefix(
                #"SELECT "t0"."title" AS "title", "t1"."body" AS "body", "t2"."name" AS "author", "t3"."bio" AS "bio""#
            ))
    }

    @Test("an unlabeled select(into:) tuple is caught at render time, like the other join forms")
    func invalidProjectionCaught() {
        struct Row: Decodable, Sendable { let title: String; let body: String }
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            return q.select(into: Row.self) { (post.title, comment.body) }
        }
        #expect(throws: HangarError.self) { try query.renderedQuery() }
    }

    @Test("setter methods chain: each returns the builder, not Void")
    func settersChain() {
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            q.where(post.published)
                .order(post.createdAt.desc())
                .groupBy(post.id)
                .having(comment.id.count() > 1)
                .limit(10)
                .offset(5)
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"WHERE "t0"."published""#))
        #expect(sql.contains(#"ORDER BY "t0"."created_at" DESC"#))
        #expect(sql.contains(#"GROUP BY "t0"."id""#))
        #expect(sql.contains("HAVING"))
        #expect(sql.hasSuffix("LIMIT 10 OFFSET 5"))
    }

    @Test("groupBy takes several columns of different types in one call")
    func groupByMultipleColumns() {
        let query = Post.query { q, post in
            let author = q.join(Author.self) { $0.id == post.authorID }
            // Column<UUID>, Column<String>, Column<String> — mixed types,
            // one call.
            q.groupBy(post.id, post.title, author.name)
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"GROUP BY "t0"."id", "t0"."title", "t1"."name""#))
    }

    struct PopularPost: Decodable {
        let title: String
        let author: String
        let commentCount: Int
    }

    @Test("a grouped, filtered, projected composition renders every clause it was given")
    func groupedHavingProjectionRenders() {
        // The annotation is load-bearing: it pins that the composition still
        // produces a `ComposedQuery<Post, PopularPost>` rather than some other
        // projection, which a `let` alone would infer away.
        let query: ComposedQuery<Post, PopularPost> = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            let author = q.join(Author.self) { $0.id == post.authorID }

            return q.where(post.published)
                .groupBy(post.id, post.title, author.name)
                .having(comment.id.count() > 10)
                .select(into: PopularPost.self) {
                    (
                        title: post.title,
                        author: author.name,
                        commentCount: comment.id.count()
                    )
                }
        }

        // Constructing it proved only that it type-checks. These assert the
        // clauses actually reach the statement — a projection that silently
        // dropped its HAVING, or grouped by the wrong columns, would have
        // compiled and executed just as happily.
        let sql = query.debugSQL
        #expect(sql.contains(#"WHERE "t0"."published""#))
        #expect(sql.contains(#"GROUP BY "t0"."id", "t0"."title", "t2"."name""#))
        #expect(sql.contains("HAVING"))
        #expect(sql.contains("count("))
        #expect(sql.contains(#"JOIN "hangar_comments""#))
        #expect(sql.contains(#"JOIN "hangar_authors""#))
    }

    @Test("groupBy calls accumulate rather than replace, single-arg and multi-arg mixed")
    func groupByAccumulates() {
        let query = Post.query { q, post in
            let author = q.join(Author.self) { $0.id == post.authorID }
            q.groupBy(post.id, post.title)
                .groupBy(author.name)
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.contains(#"GROUP BY "t0"."id", "t0"."title", "t1"."name""#))
    }

    @Test("distinct/lock/withDeleted also chain, and a chain call can stand alone unassigned")
    func remainingSettersChainAndAreDiscardable() {
        let query = Post.query { q, _ in
            // Discarding the chain's return is fine — @discardableResult —
            // exactly like the existing non-chained call sites elsewhere in
            // this file.
            q.distinct()
                .lockForUpdate()
                .withDeleted()
            return q.query()
        }
        let sql = query.debugSQL
        #expect(sql.hasPrefix("SELECT DISTINCT "))
        #expect(sql.hasSuffix("FOR UPDATE"))
    }
}

// MARK: - Integration

extension PostgresIntegrationSuite {
    @Suite("Table.query { } composed joins (real Postgres)")
    struct ComposedQueryIntegrationTests {

        @Test("post → comment → author → profile, projected across all four, real rows")
        func fourTableEndToEnd() async throws {
            try await withRepo { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                _ = try await repo.insert(Profile(id: UUID(), authorID: ada.id, bio: "mathematician"))
                var post = Post.sample(title: "on joins")
                post.authorID = ada.id
                let stored = try await repo.insert(post)
                _ = try await repo.insert(
                    Comment(id: UUID(), postID: stored.id, authorID: ada.id, moderatorID: nil, body: "nice"))

                struct Row: Decodable, Sendable {
                    let title: String
                    let body: String
                    let author: String
                    let bio: String
                }
                let rows = try await repo.all(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        let author = q.join(Author.self) { $0.id == comment.authorID }
                        let profile = q.join(Profile.self) { $0.authorID == author.id }
                        q.where(author.name != "banned")
                        return q.select(into: Row.self) {
                            (title: post.title, body: comment.body, author: author.name, bio: profile.bio)
                        }
                    })
                #expect(rows.count == 1)
                #expect(rows.first?.title == "on joins")
                #expect(rows.first?.body == "nice")
                #expect(rows.first?.author == "ada")
                #expect(rows.first?.bio == "mathematician")
            }
        }

        @Test("the base-entity path decodes Post itself, not just projections")
        func baseEntityPath() async throws {
            try await withRepo { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                var post = Post.sample(title: "base path")
                post.authorID = ada.id
                let stored = try await repo.insert(post)
                _ = try await repo.insert(
                    Comment(id: UUID(), postID: stored.id, authorID: ada.id, moderatorID: nil, body: "hi"))

                let posts = try await repo.all(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        _ = q.join(Author.self) { $0.id == comment.authorID }
                        return q.query()
                    })
                #expect(posts.map(\.title) == ["base path"])
            }
        }

        @Test("repo.one refuses more than one match, the same as every other join form")
        func oneRefusesMultipleMatches() async throws {
            try await withRepo { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                var post = Post.sample(title: "duplicated")
                post.authorID = ada.id
                let stored = try await repo.insert(post)
                for body in ["first", "second"] {
                    _ = try await repo.insert(
                        Comment(id: UUID(), postID: stored.id, authorID: ada.id, moderatorID: nil, body: body))
                }
                await #expect(throws: HangarError.self) {
                    _ = try await repo.one(
                        Post.query { q, post in
                            _ = q.join(Comment.self) { $0.postID == post.id }
                            return q.query()
                        })
                }
            }
        }
    }
}

// MARK: - Aggregation / groupBy / having (verifying, not assuming, they work)

extension PostgresIntegrationSuite {
    @Suite("ComposedQuery: groupBy/having/aggregation")
    struct ComposedQueryAggregationTests {
        @Test("groupBy + having + count() aggregate through a composed join")
        func groupByHavingCount() async throws {
            try await withRepo { repo in
                let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
                let grace = try await repo.insert(Author(id: UUID(), name: "grace"))
                for (author, count) in [(ada, 3), (grace, 1)] {
                    var post = Post.sample(title: "post-\(author.name)")
                    post.authorID = author.id
                    let stored = try await repo.insert(post)
                    for i in 0..<count {
                        _ = try await repo.insert(
                            Comment(id: UUID(), postID: stored.id, authorID: author.id, moderatorID: nil, body: "c\(i)"))
                    }
                }

                struct Row: Decodable, Sendable {
                    let authorName: String
                    let commentCount: Int
                }
                let rows = try await repo.all(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        let author = q.join(Author.self) { $0.id == post.authorID }
                        q.groupBy(author.name)
                        q.having(comment.id.count() > 1)
                        return q.select(into: Row.self) {
                            (authorName: author.name, commentCount: comment.id.count())
                        }
                    })
                #expect(rows.count == 1)
                #expect(rows.first?.authorName == "ada")
                #expect(rows.first?.commentCount == 3)
            }
        }
    }
}

// MARK: - count / exists parity with the fixed-arity join forms

@Suite("ComposedQuery: count and exists — SQL")
struct ComposedQueryCountRendererTests {

    @Test("a plain composed count is one statement, no subquery")
    func plainCount() {
        let query = Post.query { q, post in
            let comment = q.join(Comment.self) { $0.postID == post.id }
            q.where(comment.body != "")
            return q.query()
        }
        let sql = SQLRenderer.count(query).sql
        #expect(sql.hasPrefix("SELECT count(*) FROM \"hangar_posts\" AS \"t0\""))
        #expect(!sql.contains("hangar_count"))
    }

    @Test("grouping counts through a subquery — the clause changes what a row is")
    func groupedCount() {
        let query = Post.query { q, post in
            _ = q.join(Comment.self) { $0.postID == post.id }
            q.groupBy(post.authorID)
            return q.query()
        }
        let sql = SQLRenderer.count(query).sql
        #expect(sql.hasPrefix("SELECT count(*) FROM ("))
        #expect(sql.contains(#"AS "hangar_count""#))
        // The inner select lists the grouping terms, not the whole entity.
        #expect(sql.contains(#"SELECT "t0"."author_id" FROM"#))
    }

    @Test("distinct counts through a subquery too, and exists follows the same rules")
    func distinctCountAndExists() {
        let query = Post.query { q, post in
            _ = q.join(Comment.self) { $0.postID == post.id }
            q.distinct()
            return q.query()
        }
        #expect(SQLRenderer.count(query).sql.hasPrefix("SELECT count(*) FROM ("))
        #expect(SQLRenderer.exists(query).sql.hasPrefix("SELECT EXISTS (SELECT DISTINCT"))

        let plain = Post.query { q, post in
            _ = q.join(Comment.self) { $0.postID == post.id }
            return q.query()
        }
        #expect(SQLRenderer.exists(plain).sql.hasPrefix("SELECT EXISTS (SELECT 1 FROM"))
    }

    @Test("count strips ordering, limit and lock — they cannot change the answer")
    func countStripsClauses() {
        let query = Post.query { q, post in
            _ = q.join(Comment.self) { $0.postID == post.id }
            q.order(post.title.asc())
            q.limit(5)
            q.lockForUpdate()
            return q.query()
        }
        let sql = SQLRenderer.count(query).sql
        #expect(!sql.contains("ORDER BY"))
        #expect(!sql.contains("LIMIT"))
        #expect(!sql.contains("FOR UPDATE"))
    }
}

extension PostgresIntegrationSuite {
    @Suite("ComposedQuery: count, exists and preloads (real Postgres)")
    struct ComposedQueryParityTests {

        private func seed(_ repo: Repo) async throws -> (author: Author, post: Post) {
            let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
            var post = Post.sample(title: "counted")
            post.authorID = ada.id
            let stored = try await repo.insert(post)
            for body in ["first", "second"] {
                _ = try await repo.insert(
                    Comment(id: UUID(), postID: stored.id, authorID: ada.id, moderatorID: nil, body: body))
            }
            return (ada, stored)
        }

        @Test("count answers matches, and .distinct() answers base rows")
        func countMatchesAndDistinctRows() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)

                let matches = try await repo.count(
                    Post.query { q, post in
                        _ = q.join(Comment.self) { $0.postID == post.id }
                        return q.query()
                    })
                #expect(matches == 2, "a one-to-many join counts matches")

                let rows = try await repo.count(
                    Post.query { q, post in
                        _ = q.join(Comment.self) { $0.postID == post.id }
                        q.distinct()
                        return q.query()
                    })
                #expect(rows == 1, ".distinct() is how you ask for base rows")
            }
        }

        @Test("exists is true for a match and false for none")
        func existsAnswersBoth() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)

                let found = try await repo.exists(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        q.where(comment.body == "first")
                        return q.query()
                    })
                #expect(found)

                let missing = try await repo.exists(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        q.where(comment.body == "nothing like this")
                        return q.query()
                    })
                #expect(!missing)
            }
        }

        @Test("a HAVING that empties the set makes exists false, not true")
        func havingEmptiesExists() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let impossible = try await repo.exists(
                    Post.query { q, post in
                        let comment = q.join(Comment.self) { $0.postID == post.id }
                        q.groupBy(post.id)
                        q.having(comment.id.count() > 99)
                        return q.query()
                    })
                #expect(!impossible)
            }
        }

        @Test("preloads on the base-entity path run after the rows decode")
        func preloadsRun() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let posts = try await repo.all(
                    Post.query { q, post in
                        _ = q.join(Author.self) { $0.id == post.authorID }
                        q.distinct()
                        q.preload(\.author)
                        q.preload(\.comments)
                        return q.query()
                    })
                #expect(posts.count == 1)
                #expect(try posts[0].author.get().name == "ada")
                #expect(try posts[0].comments.get().count == 2)
            }
        }
    }
}
