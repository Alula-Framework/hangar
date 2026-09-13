import Foundation
import Testing

@testable import Hangar

// Sandboxed (testing plan, Phase 3). Scoped by the ids `seed` returns rather
// than by title: a sandbox sees committed rows, so `where title == "both"` would
// also match a row some other suite left behind. Scoping by created id is
// order-independent, which is what lets these run concurrently.
extension SandboxedIntegrationSuite {
    @Suite("@HasMany(through:) (real Postgres, sandboxed)")
    struct ThroughAssociationTests {

        private func seed(_ repo: Repo) async throws -> (posts: [TaggedPost], tags: [Tag]) {
            let swift = try await repo.insert(Tag(id: UUID(), label: "swift"))
            let db = try await repo.insert(Tag(id: UUID(), label: "database"))
            let web = try await repo.insert(Tag(id: UUID(), label: "web"))

            let both = try await repo.insert(TaggedPost(id: UUID(), title: "both"))
            let one = try await repo.insert(TaggedPost(id: UUID(), title: "one"))
            let none = try await repo.insert(TaggedPost(id: UUID(), title: "none"))

            for (post, tag) in [(both, swift), (both, db), (one, web)] {
                _ = try await repo.insert(PostTag(id: UUID(), postID: post.id, tagID: tag.id))
            }
            return ([both, one, none], [swift, db, web])
        }

        @Test("two batched queries load every parent's tags, empty included")
        func batchedLoading() async throws {
            try await withSandbox { repo in
                let (posts, _) = try await seed(repo)
                let all = try await repo.all(
                    TaggedPost.where { $0.id.in(posts.map(\.id)) }
                        .order { $0.title.asc() }
                        .preload(\.tags))
                #expect(all.map(\.title) == ["both", "none", "one"])
                let labels = try all.map { try $0.tags.get().map(\.label).sorted() }
                #expect(labels == [["database", "swift"], [], ["web"]])
            }
        }

        @Test("the tuned child query's own order is honored per parent")
        func tunedOrdering() async throws {
            try await withSandbox { repo in
                let (posts, _) = try await seed(repo)
                let loaded = try await repo.all(
                    TaggedPost.where { $0.id == posts[0].id }
                        .preload(\.tags) { $0.order { $0.label.desc() } })
                #expect(try loaded[0].tags.get().map(\.label) == ["swift", "database"])
            }
        }

        @Test("a tuned filter narrows what loads, exactly like a direct has-many")
        func tunedFilter() async throws {
            try await withSandbox { repo in
                let (posts, _) = try await seed(repo)
                let loaded = try await repo.all(
                    TaggedPost.where { $0.id == posts[0].id }
                        .preload(\.tags) { $0.where { $0.label == "swift" } })
                #expect(try loaded[0].tags.get().map(\.label) == ["swift"])
            }
        }

        @Test("an unloaded through-association throws, like every association")
        func unloadedThrows() async throws {
            try await withSandbox { repo in
                let (posts, _) = try await seed(repo)
                let post = try await repo.one(TaggedPost.where { $0.id == posts[0].id })!
                #expect(throws: HangarError.self) {
                    _ = try post.tags.get()
                }
            }
        }

        @Test("a join row referencing a vanished child is skipped, not fatal")
        func danglingThroughRow() async throws {
            try await withSandbox { repo in
                let (posts, tags) = try await seed(repo)
                // Delete a tag out from under its join row.
                try await repo.delete(tags[0])  // "swift"
                let reloaded = try await repo.all(
                    TaggedPost.where { $0.id == posts[0].id }.preload(\.tags))
                #expect(try reloaded[0].tags.get().map(\.label) == ["database"])
            }
        }

        @Test("duplicate join rows yield duplicate children — the data's truth")
        func duplicateJoinRows() async throws {
            try await withSandbox { repo in
                let (posts, tags) = try await seed(repo)
                _ = try await repo.insert(
                    PostTag(id: UUID(), postID: posts[1].id, tagID: tags[2].id))
                let reloaded = try await repo.all(
                    TaggedPost.where { $0.id == posts[1].id }.preload(\.tags))
                #expect(try reloaded[0].tags.get().map(\.label) == ["web", "web"])
            }
        }
    }
}
