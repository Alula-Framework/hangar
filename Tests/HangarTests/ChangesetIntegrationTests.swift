import Foundation
import Testing

import Hangar

// Phase 2: changeset-driven writes against a real server.

/// An insert changeset covering every NOT-NULL column without a database
/// default. `id` is deliberately absent: the fixture table defaults it
/// (gen_random_uuid), and `let id` means a changeset *can't* set it —
/// primary keys are not writable through this path by construction.
func postChangeset(
    title: String,
    viewCount: Int = 1,
    published: Bool = true,
    status: PostStatus = .published
) -> Changeset<Post> {
    Changeset(Post.self)
        .change(\.title, title)
        .change(\.published, published)
        .change(\.viewCount, viewCount)
        .change(\.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        .change(\.status, status)
        .change(\.metadata, PostMetadata(tags: ["swift"], readingMinutes: 3))
        .change(\.authorID, UUID())
}

// Sandboxed (testing plan, Phase 3). One assertion had to change shape: the
// invalid-changeset test proved "nothing was written" with a whole-table
// `count(Post.all) == 0`, which only held because `withRepo` truncated first. It
// now counts rows carrying the title the invalid changeset tried to write, which
// is both sandbox-safe and a sharper statement of the actual claim.
extension SandboxedIntegrationSuite {
@Suite("Changeset writes (real Postgres, sandboxed)")
struct ChangesetIntegrationTests {

    @Test("insert: changed fields are written, defaults fill the rest")
    func insertChangeset() async throws {
        try await withSandbox { repo in
            let stored = try await repo.insert(
                postChangeset(title: "via changeset").validate(\.title, .length(1...80)))
            #expect(stored.title == "via changeset")
            #expect(stored.nickname == nil)
            let fetched = try await repo.all(Post.where { $0.id == stored.id })
            #expect(fetched == [stored])
        }
    }

    @Test("an invalid changeset never reaches the wire")
    func invalidChangeset() async throws {
        try await withSandbox { repo in
            let invalid = postChangeset(title: "").validate(\.title, .length(1...80))
            do {
                _ = try await repo.insert(invalid)
                Issue.record("insert should have thrown ChangesetValidationError")
            } catch let error as ChangesetValidationError {
                #expect(error.errors.map(\.field) == ["title"])
            }
            // Scoped to the row this changeset tried to write: a sandbox sees
            // committed rows, so a whole-table count would be measuring other
            // suites. "" is precisely what made the changeset invalid.
            let count = try await repo.count(Post.where { $0.title == "" })
            #expect(count == 0)
        }
    }

    @Test("update: only dirty columns are written; the rest stay intact")
    func updateChangeset() async throws {
        try await withSandbox { repo in
            let original = try await repo.insert(Post.sample(title: "before", nickname: "zed"))
            let updated = try await repo.update(
                Changeset(original: original)
                    .change(\.title, "after")
                    .change(\.viewCount, 99))
            #expect(updated.title == "after")
            #expect(updated.viewCount == 99)
            #expect(updated.nickname == "zed")
            #expect(updated.metadata == original.metadata)
        }
    }

    @Test("a no-change update changeset is a no-op, not a query")
    func noopUpdate() async throws {
        try await withSandbox { repo in
            let original = try await repo.insert(Post.sample(title: "same"))
            let changeset = Changeset(original: original)
                .change(\.title, "same")  // equals the original — not dirty
            #expect(changeset.hasChanges == false)
            let result = try await repo.update(changeset)
            #expect(result == original)
        }
    }

    @Test("cross-field rules run against effective state")
    func crossFieldRule() async throws {
        try await withSandbox { repo in
            let changeset = postChangeset(title: "ordered", viewCount: 5)
                .validate(.custom(on: \.viewCount, message: "must stay under 10") {
                    ($0.value(\.viewCount) ?? 0) < 10
                })
            let stored = try await repo.insert(changeset)
            #expect(stored.viewCount == 5)
        }
    }
}
}
