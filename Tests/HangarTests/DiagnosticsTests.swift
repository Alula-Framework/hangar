import Foundation
import Logging
import Testing

@testable import Hangar

/// Slow-query and repeated-query reporting.
///
/// Every statement is already timed; these assert that the timing becomes a
/// log line naming the SQL, because a p99 on a dashboard cannot tell you
/// *which* query is slow.
// Sandboxed (testing plan, Phase 3). No scoping needed anywhere: every
// assertion is about what Hangar *logged*, not about which rows came back, so
// `Post.all` here just means "run some statement".
extension SandboxedIntegrationSuite {
@Suite("Query diagnostics (sandboxed)")
struct DiagnosticsTests {

    private func repoWithRecorder(
        _ diagnostics: QueryDiagnostics, _ body: @Sendable (Repo, LogRecorder) async throws -> Void
    ) async throws {
        let recorder = LogRecorder()
        var logger = Logger(label: "hangar.diagnostics.test") { _ in
            RecordingLogHandler(recorder: recorder)
        }
        logger.logLevel = .debug
        try await withSandbox(logger: logger, diagnostics: diagnostics) { repo in
            try await body(repo, recorder)
        }
    }

    @Test("off by default: no warning however long a query takes")
    func offByDefault() async throws {
        try await repoWithRecorder(QueryDiagnostics()) { repo, recorder in
            _ = try await repo.all(Post.all)
            let warnings = recorder.snapshot().filter { $0.level == .warning }
            #expect(warnings.isEmpty, "diagnostics must be opt-in")
        }
    }

    @Test("a query over the threshold is named in a warning")
    func slowQueryWarns() async throws {
        // Zero means everything is slow, which is what makes this test about
        // the reporting rather than about a timing race.
        try await repoWithRecorder(.init(slowQueryThreshold: .zero)) { repo, recorder in
            _ = try await repo.all(Post.where { $0.published == true })

            let slow = recorder.snapshot().filter { $0.message == "hangar slow query" }
            #expect(!slow.isEmpty)
            let sql = slow.first?.metadata["sql"]?.description ?? ""
            #expect(sql.contains("hangar_posts"), "the warning must name the statement")
            #expect(slow.first?.metadata["duration_ms"] != nil)
            #expect(slow.first?.metadata["threshold_ms"] != nil)
        }
    }

    @Test("a threshold nothing reaches stays quiet")
    func fastQueryIsQuiet() async throws {
        try await repoWithRecorder(.init(slowQueryThreshold: .seconds(60))) { repo, recorder in
            _ = try await repo.all(Post.all)
            #expect(recorder.snapshot().filter { $0.message == "hangar slow query" }.isEmpty)
        }
    }

    @Test("the same statement repeating inside one unit of work is reported")
    func repeatedQueryWarns() async throws {
        try await repoWithRecorder(.init(repeatedQueryThreshold: 3)) { repo, recorder in
            try await repo.detectingRepeatedQueries {
                // The shape of an N+1: each query is fast, there are just too
                // many of them.
                for _ in 0..<5 { _ = try await repo.all(Post.all) }
            }

            let repeats = recorder.snapshot().filter { $0.message == "hangar repeated query" }
            #expect(repeats.count == 1)
            #expect(repeats.first?.metadata["count"]?.description == "5")
        }
    }

    @Test("repetition is counted per unit of work, not for the process")
    func countingIsScoped() async throws {
        try await repoWithRecorder(.init(repeatedQueryThreshold: 3)) { repo, recorder in
            // The same statement twice in each of two blocks is four runs
            // overall and two per block — under the threshold either way.
            for _ in 0..<2 {
                try await repo.detectingRepeatedQueries {
                    for _ in 0..<2 { _ = try await repo.all(Post.all) }
                }
            }
            #expect(recorder.snapshot().filter { $0.message == "hangar repeated query" }.isEmpty)
        }
    }

    @Test("without a threshold the block is a passthrough")
    func noThresholdIsPassthrough() async throws {
        try await repoWithRecorder(QueryDiagnostics()) { repo, recorder in
            let count = try await repo.detectingRepeatedQueries { () -> Int in
                for _ in 0..<4 { _ = try await repo.all(Post.all) }
                return 7
            }
            #expect(count == 7, "the block's value comes back untouched")
            #expect(recorder.snapshot().filter { $0.message == "hangar repeated query" }.isEmpty)
        }
    }
}
}
