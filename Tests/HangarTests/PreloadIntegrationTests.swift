import Foundation
import Testing

@testable import Hangar

// Phase 3: associations and preloading — always batched, never
// joined; loaded/unloaded is a loud runtime distinction.

@Suite("Preload SQL — one bound array, however many keys")
struct PreloadRendererTests {
    @Test("the membership test renders as column = ANY($1)")
    func anyOfRendering() {
        var query = Post.all
        query.predicate = Predicate(
            expression: .anyOf(
                .column(table: "hangar_posts", name: "author_id"),
                .bind(SQLBind { $0.append([UUID(), UUID()]) })))
        let statement = SQLRenderer.select(query)
        #expect(statement.sql.hasSuffix(#"WHERE ("author_id" = ANY($1))"#))
        #expect(statement.binds.count == 1)
    }

    @Test("association properties are not columns")
    func associationsExcludedFromSchema() {
        #expect(Post.schema.columns.map(\.name).contains("comments") == false)
        #expect(Post.schema.columns.map(\.name).contains("author") == false)
        #expect(Post.columns.map(\.name).contains("comments") == false)
        #expect(Author.schema.columns.map(\.name) == ["id", "name"])
    }

    @Test("Loadable: get() names the missing preload; loaded reads through")
    func loadable() throws {
        let unloaded: Loadable<[Comment]> = .notLoaded(association: "comments")
        #expect(unloaded.optional == nil)
        #expect(!unloaded.isLoaded)
        do {
            _ = try unloaded.get()
            Issue.record("get() on .notLoaded should throw")
        } catch let HangarError.notPreloaded(association) {
            #expect(association == "comments")
        }
        let loaded: Loadable<[Comment]> = .loaded([])
        #expect(try loaded.get() == [])
        #expect(loaded.isLoaded)
    }
}

// Converted to `withSandbox` (testing plan, Phase 2). Two changes, and the
// second is not optional:
//
// 1. `withRepo` → `withSandbox`: isolation now comes from a transaction that is
//    always rolled back, not from truncating the fixture tables under a global
//    lock. Nested under `SandboxedIntegrationSuite`, which unlike
//    `PostgresIntegrationSuite` is not `.serialized`.
//
// 2. **Every query is scoped to the rows the test itself created.** `withRepo`
//    truncated on entry, so an unscoped `Post.all` was implicitly "the rows this
//    test just inserted". A sandbox truncates nothing and sees everything
//    *committed*, including fixtures the three serialized suites leave behind —
//    so the old unscoped assertions would break, and would break
//    order-dependently. Scoping by the created ids is what makes these tests
//    independent of what else has run, which is the precondition for running
//    them in parallel at all.
extension SandboxedIntegrationSuite {
@Suite("Preloading (real Postgres, sandboxed)")
struct PreloadIntegrationTests {

    @Test("hasMany: one batched query, each parent gets exactly its children")
    func hasManyBatched() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let withComments = try await repo.insert(Post.sample(title: "commented"))
            let without = try await repo.insert(Post.sample(title: "quiet"))
            for i in 1...3 {
                try await repo.insert(
                    Comment(id: UUID(), postID: withComments.id, authorID: author.id, body: "c\(i)"))
            }

            let posts = try await repo.all(
                Post.where { $0.id.in([withComments.id, without.id]) }
                    .order { $0.title.asc() }
                    .preload(\.comments))
            #expect(posts.map(\.title) == ["commented", "quiet"])
            #expect(try posts[0].comments.get().count == 3)
            #expect(try posts[0].comments.get().allSatisfy { $0.postID == withComments.id })
            // "No comments" is data — .loaded([]), never .notLoaded.
            #expect(try posts[1].comments.get().isEmpty)
        }
    }

    @Test("an unpreloaded association fails loudly, never queries silently")
    func notPreloaded() async throws {
        try await withSandbox { repo in
            let inserted = try await repo.insert(Post.sample())
            let post = try #require(try await repo.one(Post.where { $0.id == inserted.id }))
            do {
                _ = try post.comments.get()
                Issue.record("expected HangarError.notPreloaded")
            } catch let HangarError.notPreloaded(association) {
                #expect(association == "comments")
            }
            #expect(post.author.optional == nil)
        }
    }

    @Test("belongsTo: shared parents load once and fan out")
    func belongsTo() async throws {
        try await withSandbox { repo in
            let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
            let brian = try await repo.insert(Author(id: UUID(), name: "brian"))
            var first = Post.sample(title: "a1")
            first.authorID = ada.id
            var second = Post.sample(title: "a2")
            second.authorID = ada.id
            var third = Post.sample(title: "b1")
            third.authorID = brian.id
            for post in [first, second, third] { try await repo.insert(post) }

            let posts = try await repo.all(
                Post.where { $0.id.in([first.id, second.id, third.id]) }
                    .order { $0.title.asc() }
                    .preload(\.author))
            #expect(try posts.map { try $0.author.get().name } == ["ada", "ada", "brian"])
        }
    }

    @Test("belongsTo with a dangling reference throws, not lies")
    func danglingBelongsTo() async throws {
        try await withSandbox { repo in
            let orphan = try await repo.insert(Post.sample())  // authorID references nobody
            await #expect(throws: HangarError.self) {
                _ = try await repo.all(Post.where { $0.id == orphan.id }.preload(\.author))
            }
        }
    }

    @Test("hasOne: absence is .loaded(nil), not .notLoaded")
    func hasOne() async throws {
        try await withSandbox { repo in
            let withProfile = try await repo.insert(Author(id: UUID(), name: "ada"))
            let without = try await repo.insert(Author(id: UUID(), name: "ghost"))
            try await repo.insert(
                Profile(id: UUID(), authorID: withProfile.id, bio: "wrote things"))

            let authors = try await repo.all(
                Author.where { $0.id.in([withProfile.id, without.id]) }
                    .order { $0.name.asc() }
                    .preload(\.profile))
            #expect(try authors[0].profile.get()?.bio == "wrote things")
            #expect(try authors[1].profile.get() == nil)
        }
    }

    @Test("nullable belongsTo: nil keys load .loaded(nil) without querying for them")
    func nullableBelongsTo() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let moderator = try await repo.insert(Author(id: UUID(), name: "mod"))
            let post = try await repo.insert(Post.sample())
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: author.id,
                        moderatorID: moderator.id, body: "moderated"))
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: author.id, body: "free"))

            let comments = try await repo.all(
                Comment.where { $0.postID == post.id }
                    .order { $0.body.asc() }
                    .preload(\.moderator))
            #expect(try comments[0].moderator.get() == nil)          // "free"
            #expect(try comments[1].moderator.get()?.name == "mod")  // "moderated"
        }
    }

    @Test("nested preloads compose; the nested closure tunes the child query")
    func nestedPreloads() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            try await repo.insert(
                Profile(id: UUID(), authorID: author.id, bio: "nested deep"))
            var post = Post.sample(title: "threaded")
            post.authorID = author.id
            try await repo.insert(post)
            for body in ["zeta", "alpha", "mid"] {
                try await repo.insert(
                    Comment(id: UUID(), postID: post.id, authorID: author.id, body: body))
            }

            let posts = try await repo.all(
                Post.where { $0.id == post.id }
                    .preload(\.comments) {
                        $0.order { $0.body.asc() }
                            .preload(\.author) { $0.preload(\.profile) }
                    })
            let comments = try #require(try posts.first?.comments.get())
            #expect(comments.map(\.body) == ["alpha", "mid", "zeta"])
            #expect(try comments.allSatisfy { try $0.author.get().name == "ada" })
            #expect(try comments[0].author.get().profile.get()?.bio == "nested deep")
        }
    }

    @Test("multiple preloads on one query; one() applies them too")
    func multiplePreloadsAndOne() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            var post = Post.sample(title: "full")
            post.authorID = author.id
            try await repo.insert(post)
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: author.id, body: "hi"))

            let fetched = try #require(
                try await repo.one(
                    Post.where { $0.id == post.id }.preload(\.comments).preload(\.author)))
            #expect(try fetched.comments.get().count == 1)
            #expect(try fetched.author.get().name == "ada")
        }
    }

    @Test("hasMany from the other side: an author's posts")
    func authorPosts() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            for title in ["one", "two"] {
                var post = Post.sample(title: title)
                post.authorID = author.id
                try await repo.insert(post)
            }
            let authors = try await repo.all(
                Author.where { $0.id == author.id }
                    .preload(\.posts) { $0.where { $0.published } })
            #expect(try authors[0].posts.get().count == 2)
        }
    }
}
}
