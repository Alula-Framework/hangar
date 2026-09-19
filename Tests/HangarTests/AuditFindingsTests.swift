import Foundation
import Testing

@testable import Hangar

/// One test per finding from the 0.7.0/0.8.0 audit, so none of them can come
/// back quietly. The two P0s are pinned next door in `SetOperationSafetyTests`.
@Suite("Audit findings stay fixed")
struct AuditFindingsTests {

    @Test("a combination does not re-apply the entity's soft-delete scope")
    func scopeIsNotDoubleApplied() {
        // Each branch already chose its rows. Filtering again outside made
        // `onlyDeleted().union(onlyDeleted())` contradictory — IS NOT NULL in
        // both branches, IS NULL outside — and therefore always empty.
        let deleted = StoredFile.onlyDeleted().union(StoredFile.onlyDeleted())
        let sql = SQLRenderer.select(deleted).sql
        #expect(sql.contains(#"IS NOT NULL"#))
        #expect(!sql.hasSuffix(#"WHERE ("deleted_at" IS NULL)"#))

        // And `withDeleted` is not quietly re-excluded.
        let all = StoredFile.withDeleted().union(StoredFile.withDeleted())
        #expect(!SQLRenderer.select(all).sql.contains(#""deleted_at" IS NULL"#))

        // Scoping the combination itself still works, because that is what it
        // reads as.
        let scoped = StoredFile.withDeleted().union(StoredFile.withDeleted()).onlyDeleted()
        #expect(SQLRenderer.select(scoped).sql.hasSuffix(#"WHERE ("deleted_at" IS NOT NULL)"#))
    }

    @Test("declaring one CTE value twice declares it once")
    func sameValueDeduplicates() {
        let popular = CommonTable<Post>("popular").where { $0.viewCount > 10 }
        let sql = SQLRenderer.select(Post.all.with(popular).with(popular)).sql
        #expect(sql.components(separatedBy: #""popular" AS ("#).count == 2)
    }

    @Test("a recursive step that cannot render says so in the statement")
    func stepRenderFailureIsVisible() {
        // A self-join with neither side aliased is the join the renderer
        // refuses to build. It used to become an empty string, leaving
        // `anchor UNION ALL ` for Postgres to complain about.
        let tree = CommonTable<Post>("tree")
        let sql = SQLRenderer.select(
            Post.all
                .withRecursive(tree, anchor: Post.where { $0.published }) { _ in
                    Post.join(Post.self, on: { a, b in a.id == b.authorID })
                }
                .reading(from: tree)
        ).sql
        #expect(sql.contains("hangar could not render the recursive step"))
    }

    @Test("a window function still cannot be compared in a predicate")
    func windowStaysOutOfPredicates() {
        // The header comment claiming this reached the server was stale; the
        // guard is a compile error, pinned by CI/check-invalid-queries-fail.sh.
        // This only checks the rendering path it does belong in.
        let sql = SQLRenderer.select(
            Post.select(into: WindowedRow.self) { p in
                (title: p.title, position: rowNumber().over(.order(by: p.viewCount.desc())))
            }
        ).sql
        #expect(sql.contains("OVER (ORDER BY"))
    }

    private struct WindowedRow: Decodable {
        let title: String
        let position: Int
    }
}
