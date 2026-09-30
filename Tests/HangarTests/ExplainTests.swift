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

    @Test("analyzing a write fragment is refused, and nothing is written", arguments: [
        #"DELETE FROM "hangar_posts""#,
        #"UPDATE "hangar_posts" SET "title" = 'gone'"#,
        "/* a note */ -- another\n  delete from \"hangar_posts\"",
        #"WITH gone AS (DELETE FROM "hangar_posts" RETURNING "id") SELECT count(*) FROM gone"#,
        #"SELECT * INTO "hangar_posts_copy" FROM "hangar_posts""#,
    ])
    func analyzeRefusesWrite(sql: String) async throws {
        try await withSandbox { repo in
            try await repo.insert(Post.sample(title: "survivor"))
            do {
                _ = try await repo.explain(SQLFragment(stringLiteral: sql), mode: .analyze)
                Issue.record("expected EXPLAIN ANALYZE of a write to be refused")
            } catch let error as HangarError {
                #expect(error.code == "HGR-QUERY-4115")
                #expect(error.description.contains("RollbackError.intentional"), "\(error)")
            }
            #expect(try await repo.all(Post.all).map(\.title) == ["survivor"])
        }
    }

    @Test("a typed query cannot smuggle a write in through a raw CTE")
    func analyzeRefusesTypedWriteCTE() async throws {
        try await withSandbox { repo in
            try await repo.insert(Post.sample(title: "survivor"))
            // A data-modifying CTE runs to completion whether or not the
            // outer SELECT reads it.
            let query = Post.all.with("gone", as: #"DELETE FROM "hangar_posts" RETURNING "id""#)
            await #expect(throws: HangarError.self) {
                _ = try await repo.explain(query, mode: .analyze)
            }
            #expect(try await repo.all(Post.all).map(\.title) == ["survivor"])
        }
    }

    @Test("a write is still explained with .plan, and not performed")
    func planOfWrite() async throws {
        try await withSandbox { repo in
            try await repo.insert(Post.sample(title: "survivor"))
            let plan = try await repo.explain(SQLFragment(#"DELETE FROM "hangar_posts""#))
            #expect(plan.contains("Delete on"))
            #expect(try await repo.all(Post.all).map(\.title) == ["survivor"])
        }
    }

    @Test("a read behind a comment, and a locking read, still analyze")
    func analyzeReads() async throws {
        try await withSandbox { repo in
            let fragment = try await repo.explain(
                SQLFragment("-- why is this slow\n  SELECT count(*) FROM \"hangar_posts\""), mode: .analyze)
            #expect(fragment.contains("actual"))
            let locking = try await repo.explain(Post.all.lockForUpdate(), mode: .analyze)
            #expect(locking.contains("LockRows"))
        }
    }
}
}

@Suite("Explain classifies a fragment before running it")
struct ExplainClassificationTests {
    @Test("reads are SELECT, VALUES, TABLE, or a WITH with no data-modifying keyword", arguments: [
        ("SELECT 1", true),
        ("  select * from t", true),
        ("VALUES (1), (2)", true),
        ("TABLE t", true),
        ("WITH x AS (SELECT 1) SELECT * FROM x", true),
        ("-- note\nSELECT 1", true),
        ("/* outer /* nested */ still comment */ SELECT 1", true),
        ("DELETE FROM t", false),
        ("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", false),
        ("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", false),
        ("WITH x AS (SELECT 1) MERGE INTO t USING x ON true WHEN MATCHED THEN DO NOTHING", false),
        ("SELECT * INTO t2 FROM t", false),
        ("SELECT * FROM t FOR UPDATE", false),
        ("SELECT * FROM t FOR SHARE", false),
        ("(SELECT 1)", true),
        ("(WITH x AS (DELETE FROM t RETURNING *) SELECT 1)", false),
        ("EXECUTE plan", false),
        ("CREATE TABLE t2 AS SELECT 1", false),
        ("/* unterminated SELECT 1", false),
        (#"SELECT "share", "into" FROM t"#, true),
        ("SELECT 'delete me', 'it''s' FROM t", true),
        ("SELECT * FROM t WHERE id = $1", true),
        ("SELECT '\"' INTO t2 FROM t WHERE c = '\"'", false),
        ("SELECT $$DELETE$$", false),
        ("SELECT E'\\' ' DELETE", false),
        ("SELECT 'unterminated", false),
        ("", false),
    ])
    func classify(sql: String, isRead: Bool) {
        #expect(ExplainTarget.isRead(sql) == isRead, "\(sql)")
    }
}

extension PostgresIntegrationSuite {
@Suite("Explain routes a write to the primary (real Postgres)")
struct ExplainRoutingTests {
    @Test("a write's plan comes from the primary; a read's still from the replica")
    func writePlanOnPrimary() async throws {
        // The replica is an empty database: explaining anything against the
        // fixture tables there fails with 42P01, so success means primary.
        let primaryClient = PostgresClient(configuration: try TestDatabase.clientConfiguration())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await primaryClient.run() }
            _ = try? await primaryClient.query(
                PostgresQuery(unsafeSQL: #"CREATE DATABASE "hangar_explain_replica_test""#), logger: nil)
            var replicaConfig = try TestDatabase.clientConfiguration()
            replicaConfig.database = "hangar_explain_replica_test"
            let replicaClient = PostgresClient(configuration: replicaConfig)
            group.addTask { await replicaClient.run() }
            try await TestSchema.shared.ensure(primaryClient)

            let repo = Repo(primary: primaryClient, replica: replicaClient)
            let plan = try await repo.explain(
                SQLFragment(#"UPDATE "hangar_posts" SET "title" = 'x'"#))
            #expect(plan.contains("Update on"))
            let locking = try await repo.explain(Post.all.lockForUpdate())
            #expect(locking.contains("LockRows"))

            // The control: a read still goes to the replica, which has no
            // such table.
            do {
                _ = try await repo.explain(SQLFragment(#"SELECT * FROM "hangar_posts""#))
                Issue.record("expected the read to reach the empty replica")
            } catch let error as DatabaseError {
                #expect(error.sqlState == "42P01")
            }
            group.cancelAll()
        }
    }
}
}
