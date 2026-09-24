import Foundation
import PropertyBased
import Testing

@testable import Hangar

// Upsert covered one shape: ON CONFLICT (columns) DO NOTHING / DO UPDATE on a
// single changeset. Missing were the other ways Postgres names a conflict (a
// constraint, a partial unique index), a conditional DO UPDATE, and bulk
// upsert — and nothing refused `DO UPDATE` without a target, which Postgres
// rejects and sql-kit still emits (its own test pins the broken string).

@Entity("hangar_upsert_docs")
struct UpsertDoc: Sendable, Equatable {
    @ID let id: UUID
    var slug: String
    var version: Int
    var body: String
    @Column("deleted_at") var deletedAt: Date?
}

@Suite("Upsert rendering")
struct UpsertRenderingTests {
    let doc = UpsertDoc(id: UUID(), slug: "s", version: 1, body: "b", deletedAt: nil)

    @Test("a constraint, a partial index, and a conditional update each render")
    func clauses() throws {
        #expect(try SQLRenderer.insert([doc], onConflict: .doNothing(constraint: "docs_slug_key")).sql
            .contains(#"ON CONFLICT ON CONSTRAINT "docs_slug_key" DO NOTHING"#))

        let partial = try SQLRenderer.insert(
            [doc], onConflict: .doUpdate(target: [\UpsertDoc.slug], where: { $0.deletedAt == nil }, set: [\UpsertDoc.body]))
        #expect(partial.sql.contains(#"ON CONFLICT ("slug") WHERE ("deleted_at" IS NULL) DO UPDATE SET "body" = EXCLUDED."body""#))

        let newer = try SQLRenderer.insert(
            [doc],
            onConflict: .doUpdate(
                target: [\UpsertDoc.slug], set: [\UpsertDoc.body, \UpsertDoc.version],
                updateWhere: { existing, incoming in existing.version < incoming.version }))
        #expect(newer.sql.contains(#"WHERE ("hangar_upsert_docs"."version" < "excluded"."version")"#))
    }

    @Test("clauses Postgres would reject are refused before sending")
    func refusals() {
        #expect(throws: HangarError.self) {
            try SQLRenderer.insert([doc], onConflict: .doUpdate(target: [], set: [\UpsertDoc.body]))
        }
        #expect(throws: HangarError.self) {
            try SQLRenderer.insert([doc], onConflict: .doUpdate(target: [\UpsertDoc.slug], set: []))
        }
        #expect(throws: HangarError.self) {
            try SQLRenderer.insert([doc], onConflict: .doNothing(constraint: ""))
        }
    }

    @Test("values in conflict predicates are bound, numbered after the rows'")
    func bindsFollowRows() throws {
        let statement = try SQLRenderer.insert(
            [doc, doc], onConflict: .doNothing(target: [\UpsertDoc.slug], where: { $0.version > 7 }))
        #expect(statement.sql.contains(#"WHERE ("version" > $11)"#))
        #expect(statement.binds.count == 11)
    }
}

extension PostgresIntegrationSuite {
    @Suite("Upsert against Postgres")
    struct UpsertIntegrationTests {
        static func withDocs(_ body: @escaping @Sendable (Repo) async throws -> Void) async throws {
            try await withRepo { repo in
                try await repo.execute("DROP TABLE IF EXISTS hangar_upsert_docs")
                try await repo.execute(
                    """
                    CREATE TABLE hangar_upsert_docs (
                        id uuid PRIMARY KEY, slug text NOT NULL, version bigint NOT NULL,
                        body text NOT NULL, deleted_at timestamptz,
                        CONSTRAINT docs_body_key UNIQUE (body)
                    )
                    """)
                try await repo.execute(
                    "CREATE UNIQUE INDEX docs_live_slug ON hangar_upsert_docs (slug) WHERE deleted_at IS NULL")
                var failure: (any Error)?
                do { try await body(repo) } catch { failure = error }
                try await repo.execute("DROP TABLE hangar_upsert_docs")
                if let failure { throw failure }
            }
        }

        static func doc(_ slug: String, _ version: Int, body: String? = nil, deleted: Bool = false) -> UpsertDoc {
            UpsertDoc(
                id: UUID(), slug: slug, version: version, body: body ?? "\(slug)-v\(version)",
                deletedAt: deleted ? Date(timeIntervalSince1970: 0) : nil)
        }

        @Test("a partial unique index is a usable conflict target")
        func partialIndex() async throws {
            try await Self.withDocs { repo in
                try await repo.insert(Self.doc("a", 1, body: "old", deleted: true))  // outside the index
                try await repo.insert(Self.doc("a", 1))
                let written = try await repo.insert(
                    [Self.doc("a", 2)],
                    onConflict: .doUpdate(target: [\UpsertDoc.slug], where: { $0.deletedAt == nil }, set: [\UpsertDoc.version, \UpsertDoc.body]))
                #expect(written.map(\.version) == [2])
                #expect(try await repo.count(UpsertDoc.all) == 2)
            }
        }

        @Test("a conflict named by constraint")
        func constraintName() async throws {
            try await Self.withDocs { repo in
                try await repo.insert(Self.doc("a", 1, body: "same"))
                let skipped = try await repo.insert(
                    [Self.doc("b", 1, body: "same"), Self.doc("c", 1)], onConflict: .doNothing(constraint: "docs_body_key"))
                #expect(skipped.map(\.slug) == ["c"])
            }
        }

        @Test("a conditional update leaves the row alone when the condition fails")
        func conditional() async throws {
            try await Self.withDocs { repo in
                try await repo.insert(Self.doc("a", 5))
                let policy = OnConflict<UpsertDoc>.doUpdate(
                    target: [\UpsertDoc.slug], where: { $0.deletedAt == nil }, set: [\UpsertDoc.version, \UpsertDoc.body],
                    updateWhere: { existing, incoming in existing.version < incoming.version })
                #expect(try await repo.insert([Self.doc("a", 3)], onConflict: policy).isEmpty)
                #expect(try await repo.insert([Self.doc("a", 9)], onConflict: policy).map(\.version) == [9])
                #expect(try await repo.all(UpsertDoc.all).map(\.version) == [9])
            }
        }

        /// Each row is one integer: slug `n % 4`, version `n / 4` (0…9).
        static let batches = Gen.int(in: 0...39).array(of: 1...4).array(of: 1...6)

        @Test("generated upsert batches leave exactly what a newest-version-wins model predicts")
        func newestWins() async throws {
            try await Self.withDocs { repo in
                await propertyCheck(count: 60, input: Self.batches) { batches in
                    try await repo.execute("DELETE FROM hangar_upsert_docs")
                    var model: [String: Int] = [:]
                    let policy = OnConflict<UpsertDoc>.doUpdate(
                        target: [\UpsertDoc.slug], where: { $0.deletedAt == nil }, set: [\UpsertDoc.version, \UpsertDoc.body],
                        updateWhere: { existing, incoming in existing.version < incoming.version })
                    for encoded in batches {
                        let slugs = ["a", "b", "c", "d"]
                        let batch = encoded.map { (slugs[$0 % 4], $0 / 4) }
                        // One row per slug per statement: Postgres refuses a
                        // DO UPDATE that would touch a row twice.
                        var seen = Set<String>()
                        let rows = batch.filter { seen.insert($0.0).inserted }
                        let written = try await repo.insert(rows.map { Self.doc($0.0, $0.1) }, onConflict: policy)
                        let expected = rows.filter { slug, version in (model[slug].map { $0 < version } ?? true) }
                        #expect(written.map { [$0.slug: $0.version] } == expected.map { [$0.0: $0.1] }, "\(batches)")
                        for (slug, version) in expected { model[slug] = version }
                    }
                    let stored = try await repo.all(UpsertDoc.all)
                    #expect(Dictionary(uniqueKeysWithValues: stored.map { ($0.slug, $0.version) }) == model, "\(batches)")
                }
            }
        }
    }
}
