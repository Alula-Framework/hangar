import Foundation
import Testing

@testable import Hangar

// `nickname != "alice"` drops the rows whose nickname is NULL — SQL's
// three-valued answer, which Hangar keeps consistent with `!(==)`. There was
// no way to ask Swift's question instead; `isDistinct(from:)` is it.

@Suite("NULL-aware comparison")
struct NullComparisonUnitTests {
    @Test("IS DISTINCT FROM binds its value, and nil collapses to a NULL test")
    func rendering() throws {
        #expect(try Post.where { $0.nickname.isDistinct(from: "alice") }.renderedQuery().sql
            .contains(#""nickname" IS DISTINCT FROM $1"#))
        #expect(try Post.where { $0.nickname.isNotDistinct(from: "alice") }.renderedQuery().sql
            .contains(#""nickname" IS NOT DISTINCT FROM $1"#))
        #expect(try Post.where { $0.nickname.isDistinct(from: nil) }.renderedQuery().sql
            .contains(#""nickname" IS NOT NULL"#))
        #expect(try Post.where { $0.nickname.isNotDistinct(from: nil) }.renderedQuery().sql
            .contains(#""nickname" IS NULL"#))
    }
}

extension SandboxedIntegrationSuite {
    @Suite("NULL-aware comparison against Postgres (sandboxed)")
    struct NullComparisonIntegrationTests {
        @Test("!= follows SQL and drops NULL; isDistinct(from:) follows Swift and keeps it")
        func distinctKeepsNull() async throws {
            try await withSandbox { repo in
                let author = Author(id: UUID(), name: "A")
                try await repo.insert(author)
                for nickname in [nil, "alice", "bob"] as [String?] {
                    try await repo.insert(
                        Post(
                            id: UUID(), title: nickname ?? "none", published: true, viewCount: 0,
                            createdAt: Date(), nickname: nickname, status: .published,
                            metadata: PostMetadata(tags: [], readingMinutes: 1), authorID: author.id))
                }
                let scope = Post.where { $0.authorID == author.id }
                let notEqual = try await repo.all(scope.where { $0.nickname != "alice" }).map(\.title)
                let distinct = try await repo.all(scope.where { $0.nickname.isDistinct(from: "alice") }).map(\.title)
                #expect(Set(notEqual) == ["bob"])
                #expect(Set(distinct) == ["none", "bob"])
            }
        }
    }
}
