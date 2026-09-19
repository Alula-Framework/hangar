import Foundation
import Testing

@testable import Hangar

@Suite("Scalar subqueries — rendering")
struct ScalarSubqueryRenderingTests {

    private struct Counted: Decodable, Equatable {
        let title: String
        let comments: Int
    }

    @Test("a correlated count renders inline, qualified on both sides")
    func countRenders() {
        let sql = SQLRenderer.select(
            Post.select(into: Counted.self) { post in
                (title: post.title, comments: Comment.where { $0.postID == post.id }.scalarCount())
            }
        ).sql
        // Qualified inside the subquery, because the inner and outer tables
        // share one namespace there.
        #expect(
            sql.contains(
                #"(SELECT count(*) FROM "hangar_comments" WHERE ("hangar_comments"."post_id" = "hangar_posts"."id")) AS "comments""#
            ))
    }

    @Test("a scalar column subquery takes LIMIT 1")
    func scalarTakesLimit() {
        let sql = SQLRenderer.select(
            Post.select(into: Counted.self) { post in
                (
                    title: post.title,
                    comments: Comment.where { $0.postID == post.id }.scalar { $0.id }
                )
            }
        ).sql
        #expect(sql.contains("LIMIT 1)"))
    }

    @Test("binds inside the subquery are numbered with everything else")
    func bindsShareNumbering() {
        let statement = SQLRenderer.select(
            Post.where { $0.published == true }
                .select(into: Counted.self) { post in
                    (
                        title: post.title,
                        comments: Comment.where { $0.postID == post.id && $0.body != "" }
                            .scalarCount()
                    )
                })
        // One bind in the subquery (the empty body), one in the outer WHERE.
        #expect(statement.binds.count == 2)
        // The select list renders before the outer WHERE, so the subquery's
        // bind is $1 — which is the ordering the writer has to preserve.
        let subquery = statement.sql.range(of: "count(*)")!
        let dollarOne = statement.sql.range(of: "$1")!
        #expect(dollarOne.lowerBound > subquery.lowerBound)
    }
}

extension PostgresIntegrationSuite {

    /// Scalar subqueries against a real server.
    ///
    /// The rendering test proves the text; only the server proves the number
    /// beside each row is that row's. A subquery that lost its correlation
    /// would still render, still run, and return the same total everywhere —
    /// which is why the fixture gives each post a different number of
    /// comments.
    @Suite("Scalar subqueries (real Postgres)")
    struct ScalarSubqueryIntegrationTests {

        private struct Counted: Decodable, Equatable {
            let title: String
            let comments: Int
        }

        @Test("each row carries its own count, not the table's")
        func correlatedCount() async throws {
            try await withRepo { repo in
                let two = try await repo.insert(Post.sample(title: "two"))
                let one = try await repo.insert(Post.sample(title: "one"))
                _ = try await repo.insert(Post.sample(title: "none"))
                for body in ["a", "b"] {
                    _ = try await repo.insert(
                        Comment(id: UUID(), postID: two.id, authorID: UUID(), body: body))
                }
                _ = try await repo.insert(
                    Comment(id: UUID(), postID: one.id, authorID: UUID(), body: "c"))

                let rows = try await repo.all(
                    Post.select(into: Counted.self) { post in
                        (
                            title: post.title,
                            comments: Comment.where { $0.postID == post.id }.scalarCount()
                        )
                    }
                    .order { $0.title.asc() })

                #expect(
                    rows == [
                        Counted(title: "none", comments: 0),
                        Counted(title: "one", comments: 1),
                        Counted(title: "two", comments: 2),
                    ])
            }
        }
    }
}
