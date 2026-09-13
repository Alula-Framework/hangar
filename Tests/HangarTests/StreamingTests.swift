import Foundation
import Testing

@testable import Hangar

// Streaming (`repo.stream`) and the schema precomputation behind it — the
// performance pass's user-visible surface.

@Suite("Precomputed schema metadata stays consistent with the columns")
struct SchemaPrecomputationTests {

    @Test("derived subsets match what filtering the columns would produce")
    func derivedSubsets() {
        #expect(Post.schema.primaryKey.map(\.name) == Post.schema.columns.filter(\.isPrimaryKey).map(\.name))
        #expect(Post.schema.insertable.map(\.name) == Post.schema.columns.filter { !$0.isGenerated }.map(\.name))
        #expect(Event.schema.insertable.map(\.name) == ["name"])
        #expect(Event.schema.updatable.map(\.name) == ["name"])
    }

    @Test("identifier quoting still escapes embedded quotes (the slow path)")
    func quotingEscapes() {
        #expect(SQLRenderer.quote("plain") == #""plain""#)
        #expect(SQLRenderer.quote(#"we"ird"#) == #""we""ird""#)
        #expect(SQLRenderer.quote(#"""#) == #""""""#)
    }

    @Test("debugSQL exposes the statement without interpolating values")
    func debugSQL() {
        let sql = Post.where { $0.title == "secret" }.debugSQL
        #expect(sql.contains("$1"))
        #expect(!sql.contains("secret"))
    }
}

// Sandboxed (testing plan, Phase 3). Five of these assert exact row counts or
// an exact ordered list, so each seeds its posts under a fresh owner id and
// scopes its query to that owner. The three lease-guard tests are left
// unscoped on purpose: they assert that iterating an escaped stream throws, and
// nothing about which rows come back.
extension SandboxedIntegrationSuite {
@Suite("Streaming (real Postgres, sandboxed)")
struct StreamingIntegrationTests {

    @Test("stream decodes every row, in order, without materializing")
    func streamFullModels() async throws {
        try await withSandbox { repo in
            let owner = UUID()
            for index in 1...25 {
                var post = Post.sample(title: "post-\(index)", viewCount: index)
                post.authorID = owner
                try await repo.insert(post)
            }
            let titles = try await repo.stream(
                Post.where { $0.authorID == owner }.order { $0.viewCount.asc() }
            ) { rows in
                var collected: [String] = []
                for try await post in rows { collected.append(post.title) }
                return collected
            }
            #expect(titles.count == 25)
            #expect(titles.first == "post-1")
            #expect(titles.last == "post-25")
        }
    }

    @Test("stream works over a projection too")
    func streamProjection() async throws {
        try await withSandbox { repo in
            let owner = UUID()
            var post = Post.sample(title: "only", viewCount: 7)
            post.authorID = owner
            try await repo.insert(post)
            let rows = try await repo.stream(
                Post.where { $0.authorID == owner }.select { ($0.title, $0.viewCount) }
            ) { rows in
                var collected: [(String, Int)] = []
                for try await row in rows { collected.append(row) }
                return collected
            }
            #expect(rows.count == 1)
            #expect(rows[0] == ("only", 7))
        }
    }

    @Test("an early break stops consuming and still releases the connection")
    func earlyBreak() async throws {
        try await withSandbox { repo in
            let owner = UUID()
            for index in 1...50 {
                var post = Post.sample(title: "p\(index)", viewCount: index)
                post.authorID = owner
                try await repo.insert(post)
            }
            let first: String? = try await repo.stream(
                Post.where { $0.authorID == owner }.order { $0.viewCount.asc() }
            ) { rows in
                for try await post in rows { return post.title }
                return nil
            }
            #expect(first == "p1")
            // The connection came back to the pool: a following query works.
            let count = try await repo.count(Post.where { $0.authorID == owner })
            #expect(count == 50)
        }
    }

    @Test("streaming an empty result set yields nothing")
    func streamEmpty() async throws {
        try await withSandbox { repo in
            let count = try await repo.stream(Post.where { $0.title == "nothing" }) { rows in
                var seen = 0
                for try await _ in rows { seen += 1 }
                return seen
            }
            #expect(count == 0)
        }
    }

    @Test("a duplicate related key no longer traps the process")
    func duplicateRelatedKeyDoesNotTrap() async throws {
        try await withSandbox { repo in
            // Two profiles for one author: @HasOne over a non-unique column
            // is a user modelling mistake. It must resolve to one row, not
            // kill the node — the trap this replaced would have.
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            try await repo.insert(Profile(id: UUID(), authorID: author.id, bio: "first"))
            try await repo.insert(Profile(id: UUID(), authorID: author.id, bio: "second"))

            let authors = try await repo.all(
                Author.where { $0.id == author.id }.preload(\.profile))
            let bio = try #require(try authors.first?.profile.get()?.bio)
            #expect(["first", "second"].contains(bio))
        }
    }
}
}

extension SandboxedIntegrationSuite {
    @Suite("Streaming — lease guard (sandboxed)")
    struct StreamLeaseTests {

        @Test("a stream that escapes its closure fails loudly on the next read")
        func escapedStreamThrows() async throws {
            try await withSandbox { repo in
                try await repo.insert(Post.sample(title: "one"))
                try await repo.insert(Post.sample(title: "two"))

                // The type system cannot forbid this copy-out (AsyncSequence
                // requires an escapable Self), so the guard is the runtime
                // lease: iterating after the closure returned must throw,
                // never read rows from a connection another query now owns.
                // Unscoped deliberately — what is asserted is the throw.
                var escaped: PostgresRowStream<Post>?
                try await repo.stream(Post.all) { stream in
                    escaped = stream
                }

                var iterator = escaped!.makeAsyncIterator()
                await #expect(throws: HangarError.self) {
                    _ = try await iterator.next()
                }
            }
        }

        @Test("an iterator made inside the closure also expires with the lease")
        func escapedIteratorThrows() async throws {
            try await withSandbox { repo in
                try await repo.insert(Post.sample(title: "one"))
                var escaped: PostgresRowStream<Post>.AsyncIterator?
                try await repo.stream(Post.all) { stream in
                    var iterator = stream.makeAsyncIterator()
                    _ = try await iterator.next()  // fine: lease is live
                    escaped = iterator
                }
                await #expect(throws: HangarError.self) {
                    _ = try await escaped!.next()
                }
            }
        }

        @Test("consuming inside the closure is unaffected by the guard")
        func normalConsumptionUnaffected() async throws {
            try await withSandbox { repo in
                let owner = UUID()
                for i in 1...3 {
                    var post = Post.sample(title: "row-\(i)")
                    post.authorID = owner
                    try await repo.insert(post)
                }
                let titles = try await repo.stream(
                    Post.where { $0.authorID == owner }.order { $0.title.asc() }
                ) { rows in
                    var collected: [String] = []
                    for try await post in rows {
                        collected.append(post.title)
                    }
                    return collected
                }
                #expect(titles == ["row-1", "row-2", "row-3"])
            }
        }
    }
}
