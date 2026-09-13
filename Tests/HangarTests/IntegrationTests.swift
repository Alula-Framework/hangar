import Foundation
import Testing

import Hangar

// The  pre-Phase-1 vertical slice, grown into the Phase-1 acceptance
// suite: macro → AST → renderer → PostgresNIO → decoder, against a real
// server.

// Sandboxed (testing plan, Phase 3). This suite was the densest user of the old
// "truncate first, then query the whole table" idiom: nearly every assertion here
// was an exact whole-table shape — `count(Post.all) == 0`, `all(Post.all).map(\.title)
// == ["after"]`, `one(Post.where { $0.published }) == nil` — which only meant
// anything because `withRepo` had just emptied the fixture tables. A sandbox
// truncates nothing and sees every *committed* row, so each of those is now
// scoped to rows this test created:
//
// - by id, where the test creates one or two rows it already holds
//   (`$0.id == post.id`, `$0.id.in([a.id, b.id])`);
// - by a fresh owner UUID stamped on `authorID`, where the claim is about a
//   *set* of rows and an id list would not express it — "nothing matches yet",
//   "these five and no others", "the count follows the predicate".
//
// The predicate under test is always kept alongside the scope rather than
// replaced by it: `published == true`, `status == .draft`, `nickname == nil`,
// `ilike("%hangar%")` and `viewCount > 10` all still do the discriminating, and
// each still has a row inside the scope that it must exclude.
extension SandboxedIntegrationSuite {
@Suite("Phase 1 end-to-end (real Postgres, sandboxed)")
struct IntegrationTests {

    // MARK: The vertical slice

    @Test("insert → select where → decode round-trips a full row")
    func verticalSlice() async throws {
        try await withSandbox { repo in
            let alice = Post.sample(title: "Alice's post", nickname: "al")
            let unpublished = Post.sample(title: "Unpublished", published: false)
            try await repo.insert(alice)
            _ = try await repo.insert(unpublished)

            // Scoped to this test's two rows; `published == true` still has to
            // pick one of them and reject the other.
            let found = try await repo.all(
                Post.where { $0.id.in([alice.id, unpublished.id]) && $0.published == true })
            #expect(found == [alice])
        }
    }

    @Test("compound where + order + limit + offset")
    func compoundQuery() async throws {
        try await withSandbox { repo in
            // Five rows under one fresh owner: limit/offset over a whole table
            // would be slicing whatever else is committed.
            let owner = UUID()
            for count in 1...5 {
                var post = Post.sample(title: "post-\(count)", viewCount: count * 10)
                post.authorID = owner
                _ = try await repo.insert(post)
            }
            let page = try await repo.all(
                Post.where { $0.authorID == owner && $0.published && $0.viewCount >= 20 }
                    .order { $0.viewCount.desc() }
                    .limit(2)
                    .offset(1))
            #expect(page.map(\.title) == ["post-4", "post-3"])
        }
    }

    @Test("enum, jsonb, and optional columns round-trip; nil renders IS NULL")
    func dialectRoundTrips() async throws {
        try await withSandbox { repo in
            let draftPost = Post.sample(title: "draft", published: false, status: .draft)
            let namedPost = Post.sample(title: "named", nickname: "zed")
            try await repo.insert(draftPost)
            try await repo.insert(namedPost)

            // One scope, three predicates: `status`, `IS NULL` and `= 'zed'` each
            // still have to separate these two rows from each other, which is
            // the whole claim. Unscoped, `nickname == nil` in particular would
            // sweep up every committed row that happens to have no nickname.
            let scope = [draftPost.id, namedPost.id]

            let drafts = try await repo.all(
                Post.where { $0.id.in(scope) && $0.status == .draft })
            #expect(drafts.map(\.title) == ["draft"])
            #expect(drafts.first?.metadata == PostMetadata(tags: ["swift", "postgres"], readingMinutes: 7))

            let anonymous = try await repo.all(
                Post.where { $0.id.in(scope) && $0.nickname == nil })
            #expect(anonymous.map(\.title) == ["draft"])
            let named = try await repo.all(
                Post.where { $0.id.in(scope) && $0.nickname == "zed" })
            #expect(named.map(\.title) == ["named"])
        }
    }

    @Test("ilike uses a bound pattern")
    func ilike() async throws {
        try await withSandbox { repo in
            let hit = Post.sample(title: "Hangar Ships")
            let miss = Post.sample(title: "unrelated")
            try await repo.insert(hit)
            try await repo.insert(miss)
            // Scoped by id: `Post.sample`'s default title is "Hello, Hangar",
            // so committed rows from the truncating suites match "%hangar%" too.
            let hits = try await repo.all(
                Post.where { $0.id.in([hit.id, miss.id]) && $0.title.ilike("%hangar%") })
            #expect(hits.map(\.title) == ["Hangar Ships"])
        }
    }

    // MARK: one / count / exists

    @Test("one returns nil, the row, or throws on ambiguity")
    func one() async throws {
        try await withSandbox { repo in
            // A fresh owner is the sandbox-safe way to say "nothing matches
            // yet", and the same scope later holds exactly two published rows,
            // which is what makes `one` ambiguous.
            let owner = UUID()
            #expect(try await repo.one(Post.where { $0.authorID == owner && $0.published }) == nil)

            var post = Post.sample()
            post.authorID = owner
            try await repo.insert(post)
            #expect(try await repo.one(Post.where { $0.id == post.id }) == post)

            var second = Post.sample(title: "second")
            second.authorID = owner
            try await repo.insert(second)
            await #expect(throws: HangarError.self) {
                _ = try await repo.one(Post.where { $0.authorID == owner && $0.published })
            }
        }
    }

    @Test("count and exists")
    func countAndExists() async throws {
        try await withSandbox { repo in
            let owner = UUID()
            #expect(try await repo.count(Post.where { $0.authorID == owner }) == 0)
            #expect(try await repo.exists(Post.where { $0.authorID == owner }) == false)
            var low = Post.sample(viewCount: 5)
            low.authorID = owner
            var high = Post.sample(viewCount: 50)
            high.authorID = owner
            try await repo.insert(low)
            try await repo.insert(high)
            #expect(try await repo.count(Post.where { $0.authorID == owner }) == 2)
            // Still the point of the test: the predicate narrows two rows to one.
            #expect(
                try await repo.count(Post.where { $0.authorID == owner && $0.viewCount > 10 }) == 1)
            #expect(try await repo.exists(Post.where { $0.authorID == owner && $0.viewCount > 10 }))
        }
    }

    // MARK: Writes

    @Test("update writes non-key columns and returns the stored row")
    func update() async throws {
        try await withSandbox { repo in
            var post = Post.sample(title: "before")
            try await repo.insert(post)
            post.title = "after"
            post.viewCount = 99
            let stored = try await repo.update(post)
            #expect(stored.title == "after")
            // Re-read by key: the claim is that the *stored* row changed, which
            // reading this one row back proves as well as a whole-table read did.
            #expect(try await repo.all(Post.where { $0.id == post.id }).map(\.title) == ["after"])
            #expect(try await repo.all(Post.where { $0.id == post.id }).map(\.viewCount) == [99])
        }
    }

    @Test("update and delete on a vanished row throw staleModel, not silence")
    func staleModel() async throws {
        try await withSandbox { repo in
            let post = Post.sample()
            try await repo.insert(post)
            try await repo.delete(post)

            await #expect(throws: HangarError.self) { try await repo.delete(post) }
            await #expect(throws: HangarError.self) { _ = try await repo.update(post) }
            // The row is still gone: neither failed write resurrected it.
            #expect(try await repo.count(Post.where { $0.id == post.id }) == 0)
        }
    }

    @Test("database-generated keys come back via RETURNING")
    func generatedKey() async throws {
        try await withSandbox { repo in
            let first = try await repo.insert(Event(name: "first"))
            let second = try await repo.insert(Event(name: "second"))
            #expect(first.id > 0)
            #expect(second.id > first.id)

            // Scoped by the generated key rather than by name: a fetch that
            // finds the row *through the returned id* is the sharper proof that
            // RETURNING handed back a real one, and other suites commit events
            // named "second" too.
            let fetched = try await repo.all(Event.where { $0.id == second.id })
            #expect(fetched == [second])
        }
    }

    // MARK: Ambient repo

    @Test("Repo.with binds the task-local; absence throws a named error")
    func ambientRepo() async throws {
        try await withSandbox { repo in
            let owner = UUID()
            var post = Post.sample()
            post.authorID = owner
            try await repo.insert(post)
            // Inside a sandbox this is a stronger check than it was: the row is
            // uncommitted, so `Repo.require()` can only see it if the ambient
            // repo really is this repo, on this connection.
            let count = try await Repo.with(repo) {
                try await Repo.require().count(Post.where { $0.authorID == owner })
            }
            #expect(count == 1)

            #expect(throws: HangarError.self) { _ = try Repo.require() }
        }
    }
}
}
