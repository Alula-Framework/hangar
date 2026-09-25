import Foundation
import Logging
import PropertyBased
import Testing

@testable import Hangar

// Findings of the external audit of 0.10.0, each pinned:
// - chunking a bulk DO UPDATE changed what it meant: repeated conflict keys
//   fail in one statement (SQLSTATE 21000) but succeeded split in two;
// - DatabaseError's description included the server's primary message,
//   which can quote data (`invalid input syntax for type integer: "…"`);
// - Page.pageCount went through Double.

extension PostgresIntegrationSuite {
    @Suite("Audit follow-ups (real Postgres)")
    struct AuditFollowUpTests {
        enum Outcome: Equatable { case written([String: Int]), refused }

        /// Runs one upsert batch and reports what it did to the table.
        static func run(_ rows: [(String, Int)], chunkLimit: Int?, in repo: Repo) async throws -> Outcome {
            try await repo.execute("DELETE FROM hangar_upsert_docs")
            _ = try await repo.insert(UpsertIntegrationTests.doc("a", 0))
            let policy = OnConflict<UpsertDoc>.doUpdate(
                target: [\UpsertDoc.slug], where: { $0.deletedAt == nil }, set: [\UpsertDoc.version])
            do {
                let models = rows.map { UpsertDoc(id: UUID(), slug: $0.0, version: $0.1, body: UUID().uuidString, deletedAt: nil) }
                _ = try await Repo.$bindParameterLimitOverride.withValue(chunkLimit) {
                    try await repo.insert(models, onConflict: policy)
                }
            } catch let error as HangarError {
                guard case .invalidConflictClause = error else { throw error }
                return .refused
            } catch let error as DatabaseError where error.sqlState == "21000" {
                return .refused
            }
            let stored = try await repo.all(UpsertDoc.all)
            return .written(Dictionary(uniqueKeysWithValues: stored.map { ($0.slug, $0.version) }))
        }

        static let batches = Gen.int(in: 0...29).array(of: 1...12)

        @Test("chunking a DO UPDATE never changes its outcome — same input, same result, split or not")
        func chunkingPreservesMeaning() async throws {
            try await UpsertIntegrationTests.withDocs { repo in
                await propertyCheck(count: 80, input: Self.batches) { encoded in
                    let rows = encoded.map { (["a", "b", "c", "d", "e"][$0 % 5], $0 / 5) }
                    let whole = try await Self.run(rows, chunkLimit: nil, in: repo)
                    // 5 columns a row: a limit of 12 binds forces two rows a statement.
                    let split = try await Self.run(rows, chunkLimit: 12, in: repo)
                    #expect(whole == split, "\(rows)")
                }
            }
        }

        @Test("a constraint-named DO UPDATE is refused rather than split, but runs whole")
        func constraintTargetNotSplit() async throws {
            try await UpsertIntegrationTests.withDocs { repo in
                let models = (0..<3).map { UpsertIntegrationTests.doc("s\($0)", $0) }
                let policy = OnConflict<UpsertDoc>.doUpdate(constraint: "docs_body_key", set: [\UpsertDoc.version])
                await #expect(throws: HangarError.self) {
                    try await Repo.$bindParameterLimitOverride.withValue(12) {
                        try await repo.insert(models, onConflict: policy)
                    }
                }
                let written = try await repo.insert(models, onConflict: policy)
                #expect(written.count == 3)
            }
        }

        @Test("a server message that quotes data stays out of the description and the log")
        func messagesNotLogged() async throws {
            let recorder = LogRecorder()
            let logger = Logger(label: "test") { _ in RecordingLogHandler(recorder: recorder) }
            try await withRepo(logger: logger, diagnostics: QueryDiagnostics()) { repo in
                do {
                    _ = try await repo.execute("SELECT (\("secret-token-42"))::int").collect()
                    Issue.record("the cast should fail")
                } catch let error as DatabaseError {
                    #expect(error.sqlState == "22P02")
                    #expect(error.message.contains("secret-token-42"), "the server's words stay reachable")
                    #expect(!"\(error)".contains("secret-token-42"))
                }
            }
            let failures = recorder.snapshot().filter { $0.message == "hangar statement failed" }
            #expect(failures.count == 1)
            #expect(!failures.contains { "\($0.metadata)".contains("secret-token-42") })
        }
    }
}

@Suite("Page count")
struct PageCountTests {
    @Test("pageCount is exact for every total, including past 2^53")
    func exact() async {
        await propertyCheck(count: 2_000, input: Gen.oneOf(Gen.int(in: 0...1_000_000), Gen.int(in: 0...(Int.max / 2)), Gen.always(Int.max), Gen.always(Int.max - 1)), Gen.int(in: 1...1_000)) { total, perPage in
            let pages = Page(items: [Int](), total: total, page: 1, perPage: perPage).pageCount
            #expect(pages == total / perPage + (total % perPage == 0 ? 0 : 1))
            // Enough pages to hold every row, and not one more.
            let (capacity, overflow) = pages.multipliedReportingOverflow(by: perPage)
            #expect(total == 0 || ((overflow || capacity >= total) && (pages - 1) * perPage < total))
        }
        #expect(Page(items: [Int](), total: (1 << 53) + 1, page: 1, perPage: 1).pageCount == (1 << 53) + 1)
    }
}
