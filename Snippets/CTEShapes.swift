// The README's common-table-expression examples, as code the build compiles.
//
// A README that shows an API is a claim about that API. These are the
// shapes the README's CTE section uses, so a signature change there breaks
// the build here rather than only misleading a reader.
import Foundation
import Hangar

// snippet.hide
@Entity("hangar_posts")
struct SnippetPost: Sendable {
    @ID var id: UUID
    var title: String
    @Column("view_count") var viewCount: Int
    @Column("author_id") var authorID: UUID
}

@Entity("hangar_nodes")
struct SnippetNode: Sendable {
    @ID var id: UUID
    var name: String
    @Column("parent_id") var parentID: UUID?
}
// snippet.show

func cteShapes(repo: Repo, rootID: UUID) async throws {
    // A CTE is a value: build it where it makes sense, pass it where it is
    // needed. The name is written once and travels with the body.
    let popular =
        CommonTable<SnippetPost>("popular")
        .where { $0.viewCount > 1_000 }
        .order { $0.viewCount.desc() }
        .limit(50)

    // Declare it, then refer to it — `select` takes one column out for a
    // membership test, `all` reads whole rows back.
    _ = try await repo.all(
        SnippetPost.all
            .with(popular)
            .where { $0.authorID.in(popular.select { $0.authorID }) })

    _ = try await repo.all(
        SnippetPost.all
            .with(popular)
            .reading(from: popular)
            .order { $0.title.asc() })

    // A recursive CTE is the same value, defined in terms of itself: the step
    // receives the CTE and joins it.
    let subtree = CommonTable<SnippetNode>("subtree")
    _ = try await repo.all(
        SnippetNode.all
            .withRecursive(subtree, anchor: SnippetNode.where { $0.id == rootID }) { found in
                SnippetNode.join(found, on: { child, parent in child.parentID == parent.id })
            }
            .reading(from: subtree))

    // Over a graph rather than a tree, ask for cycle detection — without it
    // Postgres walks a cycle until the connection dies.
    let reachable = CommonTable<SnippetNode>("reachable").detectingCycles(on: { $0.id })
    _ = try await repo.all(
        SnippetNode.all
            .withRecursive(reachable, anchor: SnippetNode.where { $0.id == rootID }) { found in
                SnippetNode.join(found, on: { child, parent in child.parentID == parent.id })
            }
            .reading(from: reachable))

    // The row that closed a cycle is dropped by default; ask for it to see it.
    _ = try await repo.all(
        SnippetNode.all
            .withRecursive(reachable, anchor: SnippetNode.where { $0.id == rootID }) { found in
                SnippetNode.join(found, on: { child, parent in child.parentID == parent.id })
            }
            .reading(from: reachable, includingCycleClosers: true))

    // A CTE may feed a bulk delete; it cannot be its target.
    _ = try await repo.delete(
        SnippetPost.all
            .with("doomed", as: SnippetPost.where { $0.viewCount == 0 })
            .where { _ in
                SQLFragment(#""hangar_posts"."id" IN (SELECT "id" FROM "doomed")"#)
            })
}
