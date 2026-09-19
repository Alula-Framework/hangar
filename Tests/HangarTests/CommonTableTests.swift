import Foundation
import Testing

@testable import Hangar

@Suite("CTE builder — rendering")
struct CommonTableRenderingTests {

    @Test("the name is written once and used everywhere")
    func nameTravelsWithTheBody() {
        let popular = CommonTable<Post>("popular")
            .where { $0.viewCount > 1_000 }
            .order { $0.viewCount.desc() }
            .limit(50)

        let sql = SQLRenderer.select(
            Post.all
                .with(popular)
                .where { $0.authorID.in(popular.select { $0.authorID }) }
        ).sql

        #expect(sql.hasPrefix(#"WITH "popular" AS (SELECT "#))
        #expect(sql.contains(#"WHERE ("view_count" > $1) ORDER BY "view_count" DESC LIMIT 50)"#))
        #expect(
            sql.contains(
                #"WHERE ("author_id" IN (SELECT "author_id" FROM "popular" AS "hangar_posts"))"#))
    }

    @Test("reading a CTE back yields whole rows of the entity")
    func readBackAsEntity() {
        let recent = CommonTable<Post>("recent").where { $0.published == true }
        // Typed on both sides: the name is never written twice.
        let sql = SQLRenderer.select(Post.all.with(recent).reading(from: recent)).sql
        #expect(sql.contains(#"FROM "recent" AS "hangar_posts""#))
    }

    @Test("declaring the same CTE twice declares it once")
    func idempotentDeclaration() {
        let popular = CommonTable<Post>("popular").where { $0.viewCount > 10 }
        let sql = SQLRenderer.select(Post.all.with(popular).with(popular)).sql
        // Postgres rejects a WITH list naming the same CTE twice, and passing
        // one value to two builders is an easy way to do it by accident.
        #expect(sql.components(separatedBy: #""popular" AS ("#).count == 2)
    }

    @Test("two different CTEs both land, in declaration order")
    func twoTables() {
        let a = CommonTable<Post>("a").where { $0.viewCount > 1 }
        let b = CommonTable<Post>("b").where { $0.viewCount > 2 }
        let sql = SQLRenderer.select(Post.all.with(a).with(b)).sql
        let indexA = sql.range(of: #""a" AS ("#)!.lowerBound
        let indexB = sql.range(of: #""b" AS ("#)!.lowerBound
        #expect(indexA < indexB)
    }

    @Test("the CTE's own binds are numbered with the outer statement's")
    func bindsShareNumbering() {
        let popular = CommonTable<Post>("popular").where { $0.viewCount > 1_000 }
        let statement = SQLRenderer.select(
            Post.all.with(popular).where { $0.title == "x" })
        #expect(statement.binds.count == 2)
        // The WITH clause renders first, so its bind is $1.
        let with = statement.sql.range(of: "$1")!
        let outer = statement.sql.range(of: "$2")!
        #expect(with.lowerBound < outer.lowerBound)
    }
}

extension PostgresIntegrationSuite {

    /// The builder against a real server.
    @Suite("CTE builder (real Postgres)")
    struct CommonTableIntegrationTests {

        @Test("a CTE built once filters the query that declares it")
        func filtersThroughCTE() async throws {
            try await withRepo { repo in
                let loud = UUID()
                let quiet = UUID()
                var a = Post.sample(title: "loud-1", viewCount: 5_000)
                a.authorID = loud
                var b = Post.sample(title: "loud-2", viewCount: 10)
                b.authorID = loud
                var c = Post.sample(title: "quiet", viewCount: 10)
                c.authorID = quiet
                for post in [a, b, c] { _ = try await repo.insert(post) }

                // Authors with at least one popular post, then everything
                // those authors wrote.
                let popular = CommonTable<Post>("popular").where { $0.viewCount > 1_000 }
                let rows = try await repo.all(
                    Post.all
                        .with(popular)
                        .where { $0.authorID.in(popular.select { $0.authorID }) }
                        .order { $0.title.asc() })

                #expect(rows.map(\.title) == ["loud-1", "loud-2"])
            }
        }
    }
}
