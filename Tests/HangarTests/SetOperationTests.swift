import Foundation
import Testing

@testable import Hangar

@Suite("Set operations — rendering")
struct SetOperationRenderingTests {

    @Test("the combination is read as a derived table aliased to the entity")
    func unionRenders() {
        let sql = SQLRenderer.select(
            Post.where { $0.viewCount > 100 }.union(Post.where { $0.published == false })
        ).sql
        // No generated name anywhere: a derived table needs none, which is
        // what makes nesting safe.
        #expect(!sql.contains("hangar_set_"))
        #expect(!sql.hasPrefix("WITH "))
        #expect(sql.contains(") UNION ("))
        // Aliased to the entity's own table, so downstream column references
        // qualify exactly as they would against the table.
        #expect(sql.contains(#") AS "hangar_posts""#))
    }

    @Test("each operator renders its own keyword")
    func operatorsRender() {
        let left = Post.where { $0.viewCount > 1 }
        let right = Post.where { $0.viewCount > 2 }
        #expect(SQLRenderer.select(left.unionAll(right)).sql.contains(") UNION ALL ("))
        #expect(SQLRenderer.select(left.intersect(right)).sql.contains(") INTERSECT ("))
        #expect(SQLRenderer.select(left.except(right)).sql.contains(") EXCEPT ("))
    }

    @Test("binds from both branches are numbered in text order")
    func bindsAreOrdered() {
        let statement = SQLRenderer.select(
            Post.where { $0.viewCount > 100 }.union(Post.where { $0.title == "x" }))
        #expect(statement.binds.count == 2)
        let first = statement.sql.range(of: "$1")
        let second = statement.sql.range(of: "$2")
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test("clauses after the combination belong to the combination")
    func outerClausesApplyToTheSet() {
        let sql = SQLRenderer.select(
            Post.where { $0.viewCount > 1 }.union(Post.where { $0.viewCount > 2 })
                .where { $0.published == true }
                .order { $0.title.asc() }
                .limit(3)
        ).sql
        // The outer WHERE reads the derived table, so it lands after its
        // alias rather than inside either branch.
        let alias = sql.range(of: #") AS "hangar_posts""#)
        let outerWhere = sql.range(of: #"WHERE ("published""#)
        #expect(alias != nil && outerWhere != nil)
        if let alias, let outerWhere { #expect(outerWhere.lowerBound > alias.lowerBound) }
        #expect(sql.hasSuffix("LIMIT 3"))
    }

    @Test("a branch's own CTEs are carried into the combined statement")
    func branchCTEsSurvive() {
        let withCTE = Post.all
            .with("recent", as: Post.where { $0.viewCount > 10 })
        let sql = SQLRenderer.select(withCTE.union(Post.where { $0.published == true })).sql
        #expect(sql.hasPrefix(#"WITH "recent" AS ("#))
    }
}

extension PostgresIntegrationSuite {

    /// Set operations against a real server.
    ///
    /// Rendering `UNION` is not the claim. The claim is that the combined rows
    /// are the ones set algebra says they are — that `union` removes the
    /// duplicate a row appearing in both branches would produce, that
    /// `unionAll` keeps it, and that `except` is the one operator where
    /// swapping the operands changes the answer.
    @Suite("Set operations (real Postgres)")
    struct SetOperationIntegrationTests {

        private func seed(_ repo: Repo) async throws {
            _ = try await repo.insert(Post.sample(title: "low", published: true, viewCount: 5))
            _ = try await repo.insert(Post.sample(title: "mid", published: true, viewCount: 50))
            _ = try await repo.insert(Post.sample(title: "high", published: false, viewCount: 500))
        }

        @Test("union removes the row both branches return; unionAll keeps it")
        func unionDeduplicates() async throws {
            try await withRepo { repo in
                try await seed(repo)
                // "mid" matches both branches.
                let left = Post.where { $0.viewCount > 10 }  // mid, high
                let right = Post.where { $0.published == true }  // low, mid

                let deduped = try await repo.all(left.union(right).order { $0.title.asc() })
                #expect(deduped.map(\.title) == ["high", "low", "mid"])

                let kept = try await repo.all(left.unionAll(right).order { $0.title.asc() })
                #expect(kept.map(\.title) == ["high", "low", "mid", "mid"])
            }
        }

        @Test("intersect returns only rows in both")
        func intersectOverlaps() async throws {
            try await withRepo { repo in
                try await seed(repo)
                let rows = try await repo.all(
                    Post.where { $0.viewCount > 10 }
                        .intersect(Post.where { $0.published == true })
                        .order { $0.title.asc() })
                #expect(rows.map(\.title) == ["mid"])
            }
        }

        @Test("except is not symmetric")
        func exceptIsOrdered() async throws {
            try await withRepo { repo in
                try await seed(repo)
                let left = Post.where { $0.viewCount > 10 }  // mid, high
                let right = Post.where { $0.published == true }  // low, mid

                let leftOnly = try await repo.all(left.except(right).order { $0.title.asc() })
                #expect(leftOnly.map(\.title) == ["high"])

                let rightOnly = try await repo.all(right.except(left).order { $0.title.asc() })
                #expect(rightOnly.map(\.title) == ["low"])
            }
        }

        @Test("clauses after the combination filter the combined set")
        func outerClausesApply() async throws {
            try await withRepo { repo in
                try await seed(repo)
                let combined = Post.where { $0.viewCount > 10 }
                    .union(Post.where { $0.published == true })

                let published = try await repo.all(
                    combined.where { $0.published == true }.order { $0.title.asc() })
                #expect(published.map(\.title) == ["low", "mid"])

                // And counting asks about the combined set too.
                #expect(try await repo.count(combined) == 3)
            }
        }

        @Test("combining two combinations works — the case that had a name collision")
        func nestedCombinations() async throws {
            try await withRepo { repo in
                try await seed(repo)
                // Two independently built combinations, combined. When each
                // side named its own CTE this produced a WITH list with the
                // same name twice, which Postgres refuses outright.
                let left = Post.where { $0.title == "low" }
                    .union(Post.where { $0.title == "mid" })
                let right = Post.where { $0.title == "high" }
                    .union(Post.where { $0.viewCount > 400 })

                let rows = try await repo.all(left.union(right).order { $0.title.asc() })
                #expect(rows.map(\.title) == ["high", "low", "mid"])
            }
        }

        @Test("a branch may carry its own limit")
        func branchesKeepTheirOwnLimits() async throws {
            try await withRepo { repo in
                try await seed(repo)
                // Parenthesising the branches is what makes this legal.
                let topOne = Post.all.order { $0.viewCount.desc() }.limit(1)  // high
                let bottomOne = Post.all.order { $0.viewCount.asc() }.limit(1)  // low
                let rows = try await repo.all(
                    topOne.union(bottomOne).order { $0.title.asc() })
                #expect(rows.map(\.title) == ["high", "low"])
            }
        }
    }
}
