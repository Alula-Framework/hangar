import Foundation
import Testing

@testable import Hangar

/// `EXPLAIN`, which is the other half of the slow-query diagnostics: those
/// say which statement is slow, this says why.
///
/// Sandboxed (testing plan, Phase 3). Nothing needed scoping here: every
/// assertion is about the *plan text*, not about which rows exist. `Post.all`
/// means "explain a whole-table scan", and what must hold is that a plan came
/// back — so committed rows left by other suites cannot affect the result.
/// `EXPLAIN ANALYZE` does really execute the statement, which is harmless inside
/// a transaction that is going to be rolled back.
extension SandboxedIntegrationSuite {
@Suite("Explain")
struct ExplainTests {

    @Test("a plan comes back as the text psql would show")
    func plan() async throws {
        try await withSandbox { repo in
            let plan = try await repo.explain(Post.where { $0.published == true })
            // Not asserting on a specific strategy — the planner is free to
            // choose, and a test that pins its choice fails on a version bump
            // for no reason. What must hold is that a plan came back and it is
            // about this table.
            #expect(!plan.isEmpty)
            #expect(plan.contains("hangar_posts"))
        }
    }

    @Test("analyze reports what actually happened")
    func analyze() async throws {
        try await withSandbox { repo in
            _ = try await repo.insert(Author(id: UUID(), name: "Ada"))
            let plan = try await repo.explain(Post.all, mode: .analyze)
            // ANALYZE adds real timings and row counts to the estimates.
            #expect(plan.contains("actual") || plan.contains("Execution Time"))
        }
    }

    @Test("the predicate reaches the planner, binds and all")
    func bindsAreApplied() async throws {
        try await withSandbox { repo in
            // A bound parameter must survive into the EXPLAIN, or the plan
            // shown is for a different query than the one that runs.
            let plan = try await repo.explain(Post.where { $0.viewCount > 5 })
            #expect(!plan.isEmpty)
            #expect(plan.lowercased().contains("filter") || plan.contains("Index"))
        }
    }

    @Test("a raw fragment can be explained too")
    func fragment() async throws {
        try await withSandbox { repo in
            let plan = try await repo.explain(
                SQLFragment("SELECT count(*) FROM \(raw: "hangar_posts")"))
            #expect(!plan.isEmpty)
        }
    }
}
}
