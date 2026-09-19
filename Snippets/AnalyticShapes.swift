// The README's window, set-operation and scalar-subquery examples, as code
// the build compiles.
//
// A README that shows an API is a claim about that API. These are the shapes
// its "What it does" section uses, so a signature change there breaks the
// build here rather than only misleading a reader.
import Foundation
import Hangar

// snippet.hide
@Entity("hangar_posts")
struct AnalyticPost: Sendable {
    @ID var id: UUID
    var title: String
    var published: Bool
    @Column("view_count") var viewCount: Int
    @Column("created_at") var createdAt: Date
    var nickname: String?
    @Column("author_id") var authorID: UUID
}

@Entity("hangar_comments")
struct AnalyticComment: Sendable {
    @ID var id: UUID
    @Column("post_id") var postID: UUID
    var body: String
}

@Entity("hangar_authors")
struct AnalyticAuthor: Sendable {
    @ID var id: UUID
    var name: String
}

struct Ranked: Decodable {
    let title: String
    let position: Int
    let authorTotal: Int?
}

struct Trailing: Decodable {
    let title: String
    let average: Double?
}

struct PostWithCount: Decodable {
    let title: String
    let comments: Int
    let author: String?
}
// snippet.show

func windowShapes(repo: Repo) async throws {
    // Every aggregate gains `.over`, and the ranking functions are free
    // functions so the call site reads as the SQL it becomes.
    let ranked = try await repo.all(
        AnalyticPost.select(into: Ranked.self) { p in
            (
                title: p.title,
                position: rowNumber().over(
                    .partition(by: p.authorID).order(by: p.viewCount.desc())),
                authorTotal: p.viewCount.sum().over(.partition(by: p.authorID))
            )
        })
    _ = ranked

    // A frame: this row and the two before it, in date order. Without one the
    // window is the whole partition, and the average never moves.
    let trailing = try await repo.all(
        AnalyticPost.select(into: Trailing.self) { p in
            (
                title: p.title,
                average: p.viewCount.avg().over(
                    .order(by: p.createdAt.asc()).rows(from: .preceding(2)))
            )
        })
    _ = trailing

    // An empty window is the whole result set.
    _ = AnalyticPost.select(into: Ranked.self) { p in
        (title: p.title, position: p.id.count().over(), authorTotal: p.viewCount.sum().over())
    }

    // `rank` and `denseRank` differ only in what a tie does to the next value.
    _ = AnalyticPost.select(into: Ranked.self) { p in
        (
            title: p.title,
            position: rank().over(.order(by: p.viewCount.desc())),
            authorTotal: p.viewCount.sum().over()
        )
    }
    _ = AnalyticPost.select(into: Ranked.self) { p in
        (
            title: p.title,
            position: denseRank().over(.order(by: p.viewCount.desc())),
            authorTotal: p.viewCount.sum().over()
        )
    }

    // `lag`/`lead` read their receiver, so they live on the column, and are
    // optional: the first row of a partition has nothing behind it.
    _ = AnalyticPost.select(into: Ranked.self) { p in
        (
            title: p.title,
            position: rowNumber().over(.order(by: p.createdAt.asc())),
            authorTotal: p.viewCount.lag().over(.order(by: p.createdAt.asc()))
        )
    }

    // NULLS placement, which the server's default does not make neutral.
    _ = AnalyticPost.all.order { $0.nickname.desc().nullsLast() }
}

func setOperationShapes(repo: Repo, cutoff: Date) async throws {
    let urgent = AnalyticPost.where { $0.viewCount > 10_000 }
    let recent = AnalyticPost.where { $0.createdAt > cutoff }

    // The combination is an ordinary query again: clauses after it apply to
    // the combined rows.
    _ = try await repo.all(
        urgent.union(recent)
            .where { $0.published }
            .order { $0.createdAt.desc() }
            .limit(20))

    // Each branch may carry its own bound — "the twenty most viewed, plus the
    // five newest" is two bounded branches.
    let mostViewed = AnalyticPost.all.order { $0.viewCount.desc() }.limit(20)
    let newest = AnalyticPost.all.order { $0.createdAt.desc() }.limit(5)
    _ = try await repo.all(mostViewed.union(newest))

    _ = try await repo.all(urgent.unionAll(recent))
    _ = try await repo.all(urgent.intersect(recent))
    _ = try await repo.all(urgent.except(recent))
}

func scalarSubqueryShapes(repo: Repo) async throws {
    // Another query as one column of this one, correlated on the outer row.
    _ = try await repo.all(
        AnalyticPost.select(into: PostWithCount.self) { post in
            (
                title: post.title,
                comments: AnalyticComment.where { $0.postID == post.id }.scalarCount(),
                author: AnalyticAuthor.where { $0.id == post.authorID }.scalar { $0.name }
            )
        })
}
