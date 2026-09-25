import Foundation
import Testing

@testable import Hangar

/// The two ways a set operation could quietly stop being one.
///
/// Both were real. A combination is carried on `fromDerived`, and anything
/// that dropped that field turned "the union of these two" back into "the
/// whole table" — with no error, because the result is still valid SQL over
/// the entity. Found in an external audit of 0.7.0/0.8.0, not by these tests,
/// which is why they exist now.
@Suite("Set operations cannot quietly stop being one")
struct SetOperationSafetyTests {

    private var combined: Query<Post, Post> {
        Post.where { $0.viewCount > 9_000 }.union(Post.where { $0.published == false })
    }

    @Test("a bulk delete over a combination is refused, not silently widened")
    func deleteIsRefused() {
        // Rendered without the guard this was `DELETE FROM "hangar_posts"` —
        // no WHERE, every row — from a call that reads as "delete the union".
        #expect(throws: HangarError.self) { try combined.debugDeleteSQL() }
    }

    /// Locking a branch used to be a precondition failure, which took the
    /// whole process down on the request that built the query. Both
    /// placements are now an error thrown before anything is sent.
    @Test("a row lock on a combination or on its branch throws HGR-QUERY-4005, rather than trapping", arguments: [
        "branch", "outer", "nested",
    ])
    func rowLockIsRefused(_ placement: String) throws {
        let locked = Post.where { $0.viewCount > 9_000 }.lockForUpdate()
        let plain = Post.where { $0.published == false }
        let query: Query<Post, Post>
        switch placement {
        case "branch": query = locked.union(plain)
        case "outer": query = combined.lockForUpdate()
        default: query = locked.union(plain).union(Post.where { $0.viewCount < 10 })
        }
        do {
            _ = try SQLRenderer.select(query).postgresQuery()
            Issue.record("a locked set operation rendered")
        } catch let error as HangarError {
            guard case .rowLockOnSetOperation = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(error.description.hasPrefix("[HGR-QUERY-4005]"))
        }
    }

    @Test("a combination without a lock still renders")
    func unlockedStillRenders() throws {
        _ = try SQLRenderer.select(combined).postgresQuery()
        _ = try SQLRenderer.select(Post.where { $0.viewCount > 1 }.lockForUpdate()).postgresQuery()
    }

    @Test("a bulk update over a combination is refused too")
    func updateIsRefused() {
        #expect(throws: HangarError.self) {
            try combined.debugUpdateSQL { $0.published.set(to: true) }
        }
    }

    @Test("projecting a combination keeps the combination")
    func selectKeepsIt() {
        #expect(SQLRenderer.select(combined.select { $0.title }).sql.contains(" UNION "))
    }

    @Test("select(into:) keeps it")
    func selectIntoKeepsIt() {
        struct Row: Decodable {
            let title: String
            let views: Int
        }
        let projected = combined.select(into: Row.self) {
            (title: $0.title, views: $0.viewCount)
        }
        #expect(SQLRenderer.select(projected).sql.contains(" UNION "))
    }

    @Test("grouping a combination keeps the combination")
    func groupByKeepsIt() {
        let grouped = combined.groupBy { $0.authorID }
        #expect(SQLRenderer.count(grouped).sql.contains(" UNION "))
    }

    @Test("every field of a query survives a retype")
    func retypeCarriesEverything() {
        // The invariant behind both bugs: a transformation from Query<A, B> to
        // Query<A, C> has to account for every field, and the way that gets
        // broken is a new field added to one copier and not the other. Mirror
        // is the only thing here that notices a field nobody copied.
        struct Row: Decodable {
            let title: String
            let views: Int
        }
        var source = Post.where { $0.viewCount > 1 }
            .union(Post.where { $0.viewCount > 2 })
            .order { $0.title.asc() }
            .limit(5)
            .offset(2)
            .distinct()
            .with("aside", as: Post.where { $0.published })
        source.rowLock = .update

        let projected = source.select(into: Row.self) {
            (title: $0.title, views: $0.viewCount)
        }

        let before = Mirror(reflecting: source).children
            .reduce(into: [String: String]()) { into, child in
                guard let label = child.label, label != "selection" else { return }
                into[label] = String(describing: child.value)
            }
        let after = Mirror(reflecting: projected).children
            .reduce(into: [String: String]()) { into, child in
                guard let label = child.label, label != "selection" else { return }
                into[label] = String(describing: child.value)
            }

        for (field, value) in before {
            // `fromDerived` is a closure; its description is not stable, so it
            // is compared on presence rather than value.
            if field == "fromDerived" {
                #expect(
                    (after[field] ?? "nil").hasPrefix("Optional")
                        == value.hasPrefix("Optional"),
                    "field '\(field)' was dropped by the retype")
                continue
            }
            #expect(after[field] == value, "field '\(field)' was dropped by the retype")
        }
    }
}
