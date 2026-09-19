import Foundation
import Testing

@testable import Hangar

extension PostgresIntegrationSuite {

    /// `NULLS FIRST/LAST` against a real server.
    ///
    /// The renderer test next door proves the clause is emitted. That is not
    /// the same claim as "the rows come back in a different order", and this
    /// package's whole premise is that only the server can settle the second
    /// one — Postgres sorts NULLs *last* for ASC and *first* for DESC, so a
    /// feature that silently rendered nothing would still pass a test that
    /// only asked for ascending order.
    @Suite("NULLS placement (real Postgres)")
    struct NullsOrderingTests {

        private func seed(_ repo: Repo) async throws {
            _ = try await repo.insert(Post.sample(title: "has-nickname-a", nickname: "alice"))
            _ = try await repo.insert(Post.sample(title: "no-nickname", nickname: nil))
            _ = try await repo.insert(Post.sample(title: "has-nickname-b", nickname: "bob"))
        }

        @Test("the NULL row leads or trails as asked, against the server's own default")
        func placementMoves() async throws {
            try await withRepo { repo in
                try await seed(repo)

                // Ascending: Postgres puts NULLs last on its own, so asking
                // for first is the half that proves the clause reached the
                // server rather than being dropped on the floor.
                let ascFirst = try await repo.all(
                    Post.order { $0.nickname.asc().nullsFirst() })
                #expect(ascFirst.first?.nickname == nil)

                let ascLast = try await repo.all(
                    Post.order { $0.nickname.asc().nullsLast() })
                #expect(ascLast.last?.nickname == nil)

                // Descending: the default flips, so this is the mirror check.
                let descLast = try await repo.all(
                    Post.order { $0.nickname.desc().nullsLast() })
                #expect(descLast.last?.nickname == nil)

                let descFirst = try await repo.all(
                    Post.order { $0.nickname.desc().nullsFirst() })
                #expect(descFirst.first?.nickname == nil)

                // Every row is still present in each ordering.
                #expect(ascFirst.count == 3 && descFirst.count == 3)
            }
        }
    }
}
