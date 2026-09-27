import Foundation
import Testing

@testable import Hangar

/// One row of a feed that mixes posts and authors.
struct FeedEntry: Decodable, Sendable, Equatable {
    let id: UUID
    let text: String
}

/// A feed row that says which table it came from.
struct SourcedEntry: Decodable, Sendable, Equatable {
    let source: String
    let text: String
}

@Suite("Set operations across entities — rendering")
struct CombinedQueryRenderingTests {
    let posts = Post.all.select(into: FeedEntry.self) { (id: $0.id, text: $0.title) }
    let authors = Author.all.select(into: FeedEntry.self) { (id: $0.id, text: $0.name) }

    @Test("projections of two entities combine, ordered and limited as one")
    func renders() {
        let statement = posts.unionAll(authors.where { $0.name != "x" }).order("text", .desc).limit(5).rendered()
        #expect(statement.invalid == nil)
        #expect(
            statement.sql
                == #"(SELECT "id" AS "id", "title" AS "text" FROM "hangar_posts") UNION ALL (SELECT "id" AS "id", "name" AS "text" FROM "hangar_authors" WHERE ("name" <> $1)) ORDER BY "text" DESC LIMIT 5"#,
            "\(statement.sql)")
    }

    @Test("a branch with its labels in another order is lined up by label")
    func reorders() {
        let swapped = Author.all.select(into: FeedEntry.self) { (text: $0.name, id: $0.id) }
        let sql = posts.union(swapped).rendered().sql
        #expect(sql.contains(#"(SELECT "id" AS "id", "name" AS "text" FROM "hangar_authors")"#), "\(sql)")
    }

    @Test("a branch with different labels is refused")
    func mismatchedLabels() {
        let other = Author.all.select(into: FeedEntry.self) { (id: $0.id, body: $0.name) }
        guard case .invalidProjection(_, let reason)? = posts.union(other).rendered().invalid else {
            Issue.record("expected invalidProjection")
            return
        }
        #expect(reason.contains("same labels"), "\(reason)")
    }

    @Test("ordering by a column the combination does not have is refused")
    func unknownOrdering() {
        #expect(posts.union(authors).order("title").rendered().invalid != nil)
    }

    @Test("INTERSECT after UNION applies to the union, as the chain reads")
    func associativity() {
        let sql = posts.union(authors).intersect(posts).rendered().sql
        #expect(sql.hasPrefix("((SELECT"), "\(sql)")
        #expect(sql.contains(#"FROM "hangar_authors")) INTERSECT (SELECT"#), "\(sql)")
    }

    @Test("same-entity whole-row union still yields a Query")
    func sameEntityUnchanged() {
        let combined: Query<Post, Post> = Post.all.union(Post.where { $0.published })
        #expect(SQLRenderer.select(combined).sql.contains(") UNION ("))
    }
}

extension PostgresIntegrationSuite {
    @Suite("Set operations across entities (real Postgres)")
    struct CombinedQueryIntegrationTests {
        @Test("each branch can name its source with a constant column")
        func constantSource() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await repo.insert(Post.sample(title: "\(marker) b"))
                try await repo.insert(Author(id: UUID(), name: "\(marker) a"))
                let feed = Post.where { $0.title.hasPrefix(marker) }
                    .select(into: SourcedEntry.self) { (source: ColumnExpression.value("post"), text: $0.title) }
                    .unionAll(
                        Author.where { $0.name.hasPrefix(marker) }
                            .select(into: SourcedEntry.self) { (text: $0.name, source: ColumnExpression.value("author")) })
                    .order("text")
                let entries = try await repo.all(feed)
                #expect(entries.map(\.source) == ["author", "post"])
            }
        }

        @Test("a feed of posts and authors comes back merged, ordered and limited")
        func mergedFeed() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await repo.insert(Post.sample(title: "\(marker) b-post"))
                try await repo.insert(Post.sample(title: "\(marker) d-post"))
                try await repo.insert(Author(id: UUID(), name: "\(marker) a-author"))
                try await repo.insert(Author(id: UUID(), name: "\(marker) c-author"))
                let feed = Post.where { $0.title.hasPrefix(marker) }
                    .select(into: FeedEntry.self) { (id: $0.id, text: $0.title) }
                    .unionAll(
                        Author.where { $0.name.hasPrefix(marker) }
                            .select(into: FeedEntry.self) { (text: $0.name, id: $0.id) })
                    .order("text", .desc)
                    .limit(3)
                let entries = try await repo.all(feed)
                #expect(entries.map { $0.text.replacingOccurrences(of: "\(marker) ", with: "") } == [
                    "d-post", "c-author", "b-post",
                ])
            }
        }
    }
}
