import Foundation
import Testing

@testable import Hangar

/// What a window renders to. The integration suite next door proves the
/// numbers are right; this proves the clause is shaped the way Postgres
/// expects, which is the half that fails fastest and reads clearest.
@Suite("Window functions — rendering")
struct WindowRenderingTests {

    private struct Row: Decodable {
        let title: String
        let rank: Int
    }

    private struct Lagged: Decodable {
        let title: String
        let previous: Int?
    }

    @Test("an aggregate gains OVER without changing its call site")
    func aggregateOverPartition() {
        let query = Post.select(into: Row.self) { post in
            (title: post.title, rank: post.viewCount.sum().over(.partition(by: post.authorID)))
        }
        let sql = SQLRenderer.select(query).sql
        #expect(sql.contains(#"(sum("view_count") OVER (PARTITION BY "author_id"))::bigint"#))
    }

    @Test("an empty window is OVER (), the whole result set")
    func emptyWindow() {
        let query = Post.select(into: Row.self) { post in
            (title: post.title, rank: post.id.count().over())
        }
        #expect(SQLRenderer.select(query).sql.contains(#"count("id") OVER ()"#))
    }

    @Test("partition and order compose, in that order")
    func partitionAndOrder() {
        let query = Post.select(into: Row.self) { post in
            (
                title: post.title,
                rank: rowNumber().over(
                    .partition(by: post.authorID).order(by: post.viewCount.desc()))
            )
        }
        let sql = SQLRenderer.select(query).sql
        #expect(
            sql.contains(
                #"(row_number() OVER (PARTITION BY "author_id" ORDER BY "view_count" DESC))::int"#))
    }

    @Test("a window ORDER BY carries NULLS placement like any other ordering")
    func windowOrderingCarriesNullsPlacement() {
        let query = Post.select(into: Row.self) { post in
            (
                title: post.title,
                rank: rank().over(.order(by: post.nickname.asc().nullsLast()))
            )
        }
        #expect(
            SQLRenderer.select(query).sql
                .contains(#"OVER (ORDER BY "nickname" ASC NULLS LAST)"#))
    }

    @Test("a frame renders after the ordering, and only when asked")
    func frameRenders() {
        let unframed = Post.select(into: Row.self) { post in
            (title: post.title, rank: post.viewCount.sum().over(.order(by: post.createdAt.asc())))
        }
        #expect(!SQLRenderer.select(unframed).sql.contains("ROWS BETWEEN"))

        let trailing = Post.select(into: Row.self) { post in
            (
                title: post.title,
                rank: post.viewCount.sum().over(
                    .order(by: post.createdAt.asc()).rows(from: .preceding(2)))
            )
        }
        #expect(
            SQLRenderer.select(trailing).sql.contains(
                #"OVER (ORDER BY "created_at" ASC ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)"#))

        let whole = Post.select(into: Row.self) { post in
            (
                title: post.title,
                rank: post.viewCount.sum().over(
                    .order(by: post.createdAt.asc())
                        .rows(from: .unboundedPreceding, to: .unboundedFollowing))
            )
        }
        #expect(
            SQLRenderer.select(whole).sql.contains(
                "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"))

        let peers = Post.select(into: Row.self) { post in
            (
                title: post.title,
                rank: post.viewCount.sum().over(
                    .order(by: post.viewCount.asc()).range(from: .unboundedPreceding))
            )
        }
        #expect(
            SQLRenderer.select(peers).sql.contains(
                "RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"))
    }

    @Test("lag and lead bind their offset rather than inlining it")
    func lagBindsItsOffset() {
        let query = Post.select(into: Lagged.self) { post in
            (
                title: post.title,
                previous: post.viewCount.lag(2).over(.order(by: post.createdAt.asc()))
            )
        }
        let statement = SQLRenderer.select(query)
        // Cast, not inlined: PostgresNIO sends Int as bigint and lag wants int.
        #expect(
            statement.sql.contains(
                #"lag("view_count", ($1)::int) OVER (ORDER BY "created_at" ASC)"#))
        // The offset is a value, and values are bound. Nothing about it is
        // special because it happens to be an Int the caller typed.
        #expect(statement.binds.count == 1)
    }
}
