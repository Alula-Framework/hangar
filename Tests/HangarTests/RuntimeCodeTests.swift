import Foundation
import Testing

@testable import Hangar

@Suite("Runtime errors carry a code and a page")
struct RuntimeCodeTests {
    static let coded: [(HangarError, String)] = [
        (.transactionAborted(cause: nil), "HGR-QUERY-4101"),
        (.noAmbientRepo, "HGR-QUERY-4102"),
        (.tooManyRows(table: "t"), "HGR-QUERY-4103"),
        (.staleModel(table: "t"), "HGR-QUERY-4104"),
        (.notSoftDeletable(table: "t"), "HGR-QUERY-4105"),
        (.columnCountMismatch(table: "t", expected: 3, got: 2), "HGR-QUERY-4106"),
        (.columnDecoding(table: "t", column: "c", underlying: CancellationError()), "HGR-QUERY-4107"),
        (.invalidEnumValue(type: "Status", value: "x"), "HGR-QUERY-4108"),
        (.notPreloaded(association: "author"), "HGR-QUERY-4109"),
        (.streamLeaseExpired, "HGR-QUERY-4110"),
        (.bulkWriteClause(table: "t", operation: "delete", clause: "LIMIT"), "HGR-QUERY-4111"),
        (.unknownFilterField(table: "t", field: "f"), "HGR-QUERY-4112"),
        (.invalidFilterValue(table: "t", field: "f"), "HGR-QUERY-4113"),
        (.explainAnalyzeWrite, "HGR-QUERY-4115"),
        (.rowLockOnSetOperation(table: "t"), "HGR-QUERY-4005"),
        (.joinNeedsAlias(name: "t", selfJoin: "T"), "HGR-QUERY-4007"),
        (.joinNeedsAlias(name: "t", selfJoin: nil), "HGR-QUERY-4007"),
    ]

    @Test("each coded error leads with its code and ends with its page")
    func codes() {
        for (error, code) in Self.coded {
            #expect(error.code == code)
            #expect(error.description.hasPrefix("[\(code)] "), "\(error)")
            #expect(error.description.hasSuffix("Diagnostics/\(code).md"), "\(error)")
        }
    }

    @Test("an internal invariant has no code to look up")
    func internalUncoded() {
        let error = HangarError.unknownColumn(table: "t", column: "c")
        #expect(error.code == nil)
        #expect(!error.description.contains("[HGR-"))
    }
}

extension PostgresIntegrationSuite {
    @Suite("An undefined column or table points at migrations (real Postgres)")
    struct BehindMigrationsTests {
        @Test("42703 and 42P01 carry HGR-QUERY-4114; other errors do not", arguments: [
            ("SELECT no_such_column FROM hangar_posts", "42703", "column"),
            ("SELECT 1 FROM no_such_table", "42P01", "table"),
        ])
        func hint(sql: String, state: String, what: String) async throws {
            try await withSandbox { repo in
                do {
                    _ = try await repo.execute(SQLFragment(stringLiteral: sql)).collect()
                    Issue.record("expected \(state)")
                } catch let error as DatabaseError {
                    #expect(error.sqlState == state)
                    let hint = try #require(error.hint)
                    #expect(hint.hasPrefix("[HGR-QUERY-4114] if this \(what) belongs to an @Entity"))
                    #expect(error.description.contains(" — [HGR-QUERY-4114] "), "\(error)")
                }
            }
        }

        @Test("a unique violation has no migrations hint")
        func noHintElsewhere() {
            #expect(DatabaseError.transient(sqlState: "23505") == false)
        }
    }
}
