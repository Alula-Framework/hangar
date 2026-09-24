import Foundation
import Logging
import PostgresNIO
import PropertyBased
import Testing

@testable import Hangar

// A transaction that reports success must have committed. That sounds too
// obvious to need a test, and it was false: once any statement fails,
// Postgres aborts the whole transaction, and if the body catches that failure
// and returns, the COMMIT that follows is answered with the command tag
// ROLLBACK and no error. Hangar read only for errors, so `transaction { }`
// returned normally with none of its work saved. PostgresNIO's own
// `withTransaction` and Fluent behave the same way today.
//
// Not sandboxed: the defect lives in the outermost COMMIT, which a sandbox —
// itself a transaction — turns into a savepoint.

extension PostgresIntegrationSuite {
    @Suite("Transaction integrity (real Postgres)")
    struct TransactionIntegrityTests {

        // MARK: Regression

        @Test("a failure swallowed in the body is not reported as a commit")
        func swallowedFailureIsNotACommit() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                await #expect {
                    try await repo.transaction { tx in
                        try await tx.insert(KV(key: "fresh", value: "never saved"))
                        do { try await tx.insert(KV(key: "taken", value: "dup")) } catch {}
                    }
                } throws: { error in
                    guard case HangarError.transactionAborted(let cause) = error else { return false }
                    return cause?.isUniqueViolation == true && cause?.columnName == "key"
                }
                #expect(try await repo.all(KV.all).map(\.key) == ["taken"])
            }
        }

        @Test("the statement after a swallowed failure reports the cause, not 25P02")
        func laterStatementNamesTheCause() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                await #expect {
                    try await repo.transaction { tx in
                        do { try await tx.insert(KV(key: "taken", value: "dup")) } catch {}
                        try await tx.insert(KV(key: "after", value: "x"))
                    }
                } throws: { error in
                    guard case HangarError.transactionAborted(let cause) = error else { return false }
                    return cause?.kind == .uniqueViolation
                }
            }
        }

        @Test("a connection-pinned repo checks its COMMIT too")
        func pinnedRepoChecksCommit() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                guard case .client(let client, _) = repo.backend else {
                    Issue.record("expected a client-backed repo")
                    return
                }
                try await client.withConnection { connection in
                    let pinned = Repo(connection: connection)
                    await #expect(throws: HangarError.self) {
                        try await pinned.transaction { tx in
                            try await tx.insert(KV(key: "fresh", value: "x"))
                            do { try await tx.insert(KV(key: "taken", value: "dup")) } catch {}
                        }
                    }
                }
                #expect(try await repo.count(KV.all) == 1)
            }
        }

        @Test("a savepoint catches an expected failure and the rest commits")
        func savepointRecovers() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                try await repo.transaction { tx in
                    try await tx.insert(KV(key: "before", value: "x"))
                    do {
                        try await tx.transaction { inner in
                            try await inner.insert(KV(key: "taken", value: "dup"))
                        }
                        Issue.record("the duplicate should have thrown")
                    } catch let error as DatabaseError {
                        #expect(error.isUniqueViolation)
                    }
                    try await tx.insert(KV(key: "after", value: "x"))
                }
                #expect(try await repo.all(KV.all.order { $0.key.asc() }).map(\.key)
                    == ["after", "before", "taken"])
            }
        }

        @Test("a savepoint whose body swallows a failure refuses to release, and the outer work commits")
        func swallowedInsideSavepoint() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))
                try await repo.transaction { tx in
                    try await tx.insert(KV(key: "outer", value: "x"))
                    do {
                        try await tx.transaction { inner in
                            try await inner.insert(KV(key: "inner", value: "lost"))
                            do { try await inner.insert(KV(key: "taken", value: "dup")) } catch {}
                        }
                        Issue.record("the savepoint should have refused to release")
                    } catch HangarError.transactionAborted(let cause) {
                        #expect(cause?.isUniqueViolation == true)
                    }
                }
                #expect(try await repo.all(KV.all.order { $0.key.asc() }).map(\.key)
                    == ["outer", "taken"])
            }
        }

        @Test("a constraint checked at COMMIT surfaces as a DatabaseError")
        func deferredConstraintAtCommit() async throws {
            try await withRepo { repo in
                // Self-contained tables: a leftover reference into the fixture
                // schema would block the harness from resetting it.
                try await repo.execute("DROP TABLE IF EXISTS hangar_deferred_child, hangar_deferred_parent")
                try await repo.execute("CREATE TABLE hangar_deferred_parent (id int PRIMARY KEY)")
                try await repo.execute(
                    """
                    CREATE TABLE hangar_deferred_child (
                        parent_id int REFERENCES hangar_deferred_parent(id) DEFERRABLE INITIALLY DEFERRED
                    )
                    """)
                var outcome: (any Error)?
                do {
                    try await repo.transaction { tx in
                        // Accepted now; the foreign key is checked at COMMIT.
                        try await tx.execute("INSERT INTO hangar_deferred_child VALUES (\(42))")
                    }
                } catch {
                    outcome = error
                }
                try await repo.execute("DROP TABLE hangar_deferred_child, hangar_deferred_parent")
                #expect((outcome as? DatabaseError)?.isForeignKeyViolation == true, "\(String(describing: outcome))")
            }
        }

        // MARK: Typed errors

        @Test("constraint violations arrive typed, with names and without values")
        func typedConstraintErrors() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "taken", value: "first"))

                let unique = try await caught { try await repo.insert(KV(key: "taken", value: "secret-value")) }
                #expect(unique?.kind == .uniqueViolation)
                #expect(unique?.table == "hangar_kv")
                #expect(unique?.constraint == "hangar_kv_key_key")
                #expect(unique?.columnName == "key")
                #expect(unique.map { !"\($0)".contains("taken") } == true, "the description must not quote the row")

                let foreign = try await caught {
                    try await repo.insert(StoredFile(id: UUID(), name: "f", sizeBytes: 1, ownerID: UUID()))
                }
                #expect(foreign?.kind == .foreignKeyViolation)
                #expect(foreign?.columnName == "owner_id")

                let notNull = try await caught {
                    try await repo.execute(#"INSERT INTO "hangar_kv" ("key", "value") VALUES (\#("k"), NULL)"#)
                }
                #expect(notNull?.kind == .notNullViolation)
                #expect(notNull?.columnName == "value")

                try await repo.execute("DROP TABLE IF EXISTS hangar_checked")
                try await repo.execute("CREATE TABLE hangar_checked (n int CONSTRAINT positive CHECK (n > 0))")
                let check = try await caught { try await repo.execute("INSERT INTO hangar_checked VALUES (\(-1))") }
                #expect(check?.kind == .checkViolation)
                #expect(check?.constraint == "positive")
                try await repo.execute("DROP TABLE hangar_checked")
            }
        }

        @Test("a failure is logged with column names but never the row's values")
        func failureLogOmitsValues() async throws {
            let recorder = LogRecorder()
            let logger = Logger(label: "test") { _ in RecordingLogHandler(recorder: recorder) }
            try await withRepo(logger: logger, diagnostics: QueryDiagnostics()) { repo in
                try await repo.insert(KV(key: "ada@example.com", value: "first"))
                _ = try? await repo.insert(KV(key: "ada@example.com", value: "dup"))
            }
            let failures = recorder.snapshot().filter { $0.message == "hangar statement failed" }
            #expect(failures.count == 1)
            for entry in failures {
                #expect(entry.level == .error)
                #expect(entry.metadata["sqlstate"] == "23505")
                #expect(entry.metadata["columns"] == .array(["key"]))
                #expect(!"\(entry.metadata)".contains("ada@example.com"))
            }
        }

        // MARK: Adversarial

        /// One step of a transaction body. The interesting ones fail on
        /// purpose, in every way a body can react to a failure.
        enum Step: Sendable, Equatable {
            /// Insert a fresh key; the exception propagates if it fails.
            case insert
            /// Insert a duplicate and swallow the error — aborts the transaction.
            case swallowedDuplicate
            /// Insert a duplicate inside a savepoint and catch what it throws —
            /// the savepoint rolls back and the transaction stays healthy.
            case guardedDuplicate
            /// A savepoint that inserts fresh keys and succeeds.
            case nestedInserts(Int)
            /// A savepoint whose body swallows a duplicate; the caller catches
            /// the savepoint's refusal.
            case nestedSwallowed
        }

        static let programs = Gen.frequency(
            (4, Gen.always(Step.insert).eraseToAny()),
            (1, Gen.always(Step.swallowedDuplicate).eraseToAny()),
            (2, Gen.always(Step.guardedDuplicate).eraseToAny()),
            (2, Gen.int(in: 1...3).map { Step.nestedInserts($0) }.eraseToAny()),
            (2, Gen.always(Step.nestedSwallowed).eraseToAny())
        ).array(of: 0...8)

        /// What the program should leave behind: the keys that commit, or
        /// nil when the transaction is aborted and nothing may.
        static func expectedKeys(_ steps: [Step]) -> [String]? {
            var keys: [String] = []
            for (index, step) in steps.enumerated() {
                switch step {
                case .insert: keys.append("k\(index)")
                case .swallowedDuplicate: return nil
                case .guardedDuplicate, .nestedSwallowed: break
                case .nestedInserts(let n): keys += (0..<n).map { "k\(index)-\($0)" }
                }
            }
            return keys
        }

        @Test("a transaction that returns committed exactly its work; an aborted one committed nothing")
        func transactionOutcomeMatchesTheDatabase() async throws {
            try await withRepo { repo in
                await propertyCheck(count: 150, input: Self.programs) { steps in
                    _ = try? await repo.execute(#"DELETE FROM "hangar_kv""#)
                    try await repo.insert(KV(key: "taken", value: "first"))
                    var outcome: (any Error)?
                    do {
                        try await repo.transaction { tx in
                            for (index, step) in steps.enumerated() {
                                try await Self.run(step, index: index, in: tx)
                            }
                        }
                    } catch {
                        outcome = error
                    }
                    let stored = Set(try await repo.all(KV.all).map(\.key)).subtracting(["taken"])
                    if let expected = Self.expectedKeys(steps) {
                        #expect(outcome == nil, "\(steps) should commit, threw \(String(describing: outcome))")
                        #expect(stored == Set(expected), "\(steps)")
                    } else {
                        guard case HangarError.transactionAborted(let cause)? = outcome else {
                            Issue.record("\(steps) should report an aborted transaction, got \(String(describing: outcome))")
                            return
                        }
                        #expect(cause?.isUniqueViolation == true, "\(steps)")
                        #expect(stored.isEmpty, "\(steps) committed \(stored) after reporting an abort")
                    }
                }
            }
        }

        static func run(_ step: Step, index: Int, in tx: Repo) async throws {
            switch step {
            case .insert:
                try await tx.insert(KV(key: "k\(index)", value: "v"))
            case .swallowedDuplicate:
                do { try await tx.insert(KV(key: "taken", value: "dup")) } catch {}
            case .guardedDuplicate:
                do {
                    try await tx.transaction { inner in
                        try await inner.insert(KV(key: "taken", value: "dup"))
                    }
                } catch {}
            case .nestedInserts(let n):
                try await tx.transaction { inner in
                    for i in 0..<n { try await inner.insert(KV(key: "k\(index)-\(i)", value: "v")) }
                }
            case .nestedSwallowed:
                do {
                    try await tx.transaction { inner in
                        try await inner.insert(KV(key: "k\(index)-lost", value: "v"))
                        do { try await inner.insert(KV(key: "taken", value: "dup")) } catch {}
                    }
                } catch {}
            }
        }
    }
}

private func caught(_ body: () async throws -> Void) async throws -> DatabaseError? {
    do {
        try await body()
        Issue.record("expected a database error")
        return nil
    } catch let error as DatabaseError {
        return error
    }
}

@Suite("DatabaseError parsing")
struct DatabaseErrorParsingTests {
    @Test(arguments: [
        ("Key (email)=(ada@example.com) already exists.", ["email"]),
        ("Key (a, b)=(1, 2) already exists.", ["a", "b"]),
        (#"Key ("Mixed Case", "has""quote")=(x, y) already exists."#, ["Mixed Case", #"has"quote"#]),
        (#"Key ("a,b")=(1) already exists."#, ["a,b"]),
        ("Key (lower(email))=(ada) already exists.", ["lower(email)"]),
        (#"Key (owner_id)=(9f1c…) is not present in table "hangar_authors"."#, ["owner_id"]),
        ("Failing row contains (1, null).", []),
        ("Key (email", []),
        ("", []),
    ] as [(String, [String])])
    func keyColumns(detail: String, expected: [String]) {
        #expect(DatabaseError.keyColumns(fromDetail: detail) == expected)
    }

    /// Postgres's `quote_identifier`: bare when it is a plain lowercase name,
    /// otherwise double-quoted with quotes doubled.
    static func quoted(_ name: String) -> String {
        let plain = name.first.map { $0.isLowercase || $0 == "_" } == true
            && name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }
        return plain ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static let names = Gen.frequency(
        (3, Gen.letterOrNumber.string(of: 1...12).map { $0.lowercased() }.eraseToAny()),
        (2, Gen.ascii.string(of: 1...12).eraseToAny()),
        (1, Gen.oneOf(Gen.always("a\"b"), Gen.always("x)=(y"), Gen.always("c, d"), Gen.always("é")).eraseToAny())
    ).filter { !$0.isEmpty && $0.trimmingCharacters(in: .whitespaces) == $0 }

    @Test("column names are recovered exactly, and no value ever leaks into them")
    func namesNotValues() async {
        await propertyCheck(
            count: 500, input: Self.names.array(of: 1...4), Gen.ascii.string(of: 0...30).array(of: 1...4)
        ) { names, values in
            let detail = "Key (\(names.map(Self.quoted).joined(separator: ", ")))=(\(values.joined(separator: ", "))) already exists."
            #expect(DatabaseError.keyColumns(fromDetail: detail) == names, "\(detail)")
        }
    }
}
