import Foundation
import Testing

@testable import Hangar

extension PostgresIntegrationSuite {

    /// Window functions against a real server.
    ///
    /// Rendering `OVER (PARTITION BY …)` is not the claim. The claim is that
    /// the number beside each row is the one that window implies — that
    /// `row_number()` restarts per author rather than running 1…n across the
    /// whole result, and that a running `sum()` accumulates in the window's
    /// order rather than the query's. Only the server can settle either.
    @Suite("Window functions (real Postgres)")
    struct WindowIntegrationTests {

        private struct Ranked: Decodable, Equatable {
            let title: String
            let position: Int
        }

        private struct Running: Decodable, Equatable {
            let title: String
            let total: Int?
        }

        private struct Neighbour: Decodable, Equatable {
            let title: String
            let previous: Int?
        }

        /// Two authors, so "per partition" and "across everything" differ.
        private func seed(_ repo: Repo) async throws -> (UUID, UUID) {
            let alice = UUID()
            let bob = UUID()
            for (title, views, author) in [
                ("a-low", 10, alice), ("a-high", 30, alice),
                ("b-low", 20, bob), ("b-mid", 25, bob), ("b-high", 40, bob),
            ] {
                var post = Post.sample(title: title, viewCount: views)
                post.authorID = author
                _ = try await repo.insert(post)
            }
            return (alice, bob)
        }

        @Test("row_number restarts in each partition")
        func rowNumberPerPartition() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let rows = try await repo.all(
                    Post.select(into: Ranked.self) { post in
                        (
                            title: post.title,
                            position: WindowFunctions.rowNumber().over {
                                $0.partition(by: post.authorID).order(post.viewCount.desc())
                            }
                        )
                    }
                    .order { $0.title.asc() })

                // Alice has two posts, Bob three. If the partition were
                // ignored these would run 1...5 instead.
                #expect(
                    rows == [
                        Ranked(title: "a-high", position: 1),
                        Ranked(title: "a-low", position: 2),
                        Ranked(title: "b-high", position: 1),
                        Ranked(title: "b-low", position: 3),
                        Ranked(title: "b-mid", position: 2),
                    ])
            }
        }

        @Test("a windowed sum accumulates in the window's order, not the query's")
        func runningTotal() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let rows = try await repo.all(
                    Post.where {
                        $0.title == "b-low" || $0.title == "b-mid" || $0.title == "b-high"
                    }
                    .select(into: Running.self) { post in
                        (
                            title: post.title,
                            total: post.viewCount.sum().over {
                                $0.order(post.viewCount.asc())
                            }
                        )
                    }
                    // Returned newest-first; the running total must still
                    // accumulate ascending, which is the whole point.
                    .order { $0.viewCount.desc() })

                #expect(
                    rows == [
                        Running(title: "b-high", total: 85),  // 20 + 25 + 40
                        Running(title: "b-mid", total: 45),  // 20 + 25
                        Running(title: "b-low", total: 20),
                    ])
            }
        }

        @Test("lag reads the row behind, and is NULL at the partition's start")
        func lagAcrossPartition() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let rows = try await repo.all(
                    Post.select(into: Neighbour.self) { post in
                        (
                            title: post.title,
                            previous: post.viewCount.lag().over {
                                $0.partition(by: post.authorID).order(post.viewCount.asc())
                            }
                        )
                    }
                    .order { $0.title.asc() })

                #expect(
                    rows == [
                        Neighbour(title: "a-high", previous: 10),
                        Neighbour(title: "a-low", previous: nil),  // first for alice
                        Neighbour(title: "b-high", previous: 25),
                        Neighbour(title: "b-low", previous: nil),  // first for bob
                        Neighbour(title: "b-mid", previous: 20),
                    ])
            }
        }

        private struct Trailing: Decodable, Equatable {
            let title: String
            let trailing: Int?
        }

        @Test("a frame makes a trailing sum trail — the thing a frameless window cannot do")
        func trailingSum() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let rows = try await repo.all(
                    Post.where {
                        $0.title == "b-low" || $0.title == "b-mid" || $0.title == "b-high"
                    }
                    .select(into: Trailing.self) { post in
                        (
                            title: post.title,
                            // This row and the one before it, in view order.
                            trailing: post.viewCount.sum().over {
                                $0.order(post.viewCount.asc()).rows(from: .preceding(1))
                            }
                        )
                    }
                    .order { $0.viewCount.asc() })

                // 20, then 20+25, then 25+40 — not the running total, and not
                // the partition total repeated, which is what it would be
                // without the frame.
                #expect(
                    rows == [
                        Trailing(title: "b-low", trailing: 20),
                        Trailing(title: "b-mid", trailing: 45),
                        Trailing(title: "b-high", trailing: 65),
                    ])
            }
        }

        @Test("an empty window sees every row the query returned")
        func emptyWindowCountsEverything() async throws {
            try await withRepo { repo in
                _ = try await seed(repo)
                let rows = try await repo.all(
                    Post.where { $0.viewCount >= 25 }
                        .select(into: Ranked.self) { post in
                            (title: post.title, position: post.id.count().over())
                        }
                        .order { $0.title.asc() })
                // Three rows match, and each carries that total.
                #expect(rows.map(\.position) == [3, 3, 3])
            }
        }
    }
}
