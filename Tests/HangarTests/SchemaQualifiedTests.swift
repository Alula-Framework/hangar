import Foundation
import HangarIntrospection
import Testing

@testable import Hangar

// `@Entity("billing.invoices")` quoted as one identifier — `"billing.invoices"`,
// a legal but different table — so a table outside the search_path could not
// be mapped (Fluent had the same bug until `Model.space`). `schema:` names it,
// and statements read and write `"schema"."table"` while columns keep
// qualifying by the bare table name, as Postgres resolves them.

@Entity("order", schema: "Mixed Schema")
struct SchemaOrder: Sendable, Equatable {
    @ID let id: UUID
    var label: String
    @Column("author_id") var authorID: UUID
}

@Suite("Schema-qualified entities")
struct SchemaQualifiedRenderingTests {
    @Test("every statement names the schema; columns qualify by the table alone")
    func rendering() throws {
        let order = SchemaOrder(id: UUID(), label: "x", authorID: UUID())
        #expect(try SchemaOrder.all.renderedQuery().sql.contains(#"FROM "Mixed Schema"."order""#))
        #expect(try SQLRenderer.insert(order).sql.hasPrefix(#"INSERT INTO "Mixed Schema"."order""#))
        #expect(try SQLRenderer.update(order).sql.hasPrefix(#"UPDATE "Mixed Schema"."order""#))
        let joined = try SchemaOrder.all.join(Author.self, on: { o, a in o.authorID == a.id }).renderedQuery().sql
        #expect(joined.contains(#"FROM "Mixed Schema"."order" JOIN "hangar_authors""#), "\(joined)")
        #expect(joined.contains(#""order"."label""#))
    }

    @Test("the introspector names a non-public schema")
    func introspector() {
        let table = IntrospectedTable(
            name: "invoices", schema: "billing",
            columns: [IntrospectedColumn(
                name: "id", udtName: "uuid", isNullable: false, isPrimaryKey: true, hasDefault: false, isIdentity: false)])
        #expect(EntityGenerator().generate(table).contains(#"@Entity("invoices", schema: "billing")"#))
    }
}

extension PostgresIntegrationSuite {
    @Suite("Schema-qualified entities against Postgres")
    struct SchemaQualifiedIntegrationTests {
        @Test("CRUD, joins and upserts reach the named schema, not a same-named table on the search_path")
        func crud() async throws {
            try await withRepo { repo in
                try await repo.execute(#"DROP SCHEMA IF EXISTS "Mixed Schema" CASCADE"#)
                try await repo.execute(#"DROP TABLE IF EXISTS public."order""#)
                try await repo.execute(#"CREATE SCHEMA "Mixed Schema""#)
                for target in [#""Mixed Schema"."order""#, #"public."order""#] {
                    try await repo.execute(SQLFragment(stringLiteral:
                        "CREATE TABLE \(target) (id uuid PRIMARY KEY, label text NOT NULL UNIQUE, author_id uuid NOT NULL)"))
                }
                var failure: (any Error)?
                do {
                    let author = try await repo.insert(Author(id: UUID(), name: "Ada"))
                    let order = try await repo.insert(SchemaOrder(id: UUID(), label: "first", authorID: author.id))
                    var changed = order
                    changed.label = "renamed"
                    try await repo.update(changed)
                    _ = try await repo.insert(
                        [SchemaOrder(id: UUID(), label: "renamed", authorID: author.id)],
                        onConflict: .doNothing(target: [\SchemaOrder.label]))
                    let joined = try await repo.all(
                        SchemaOrder.all.join(Author.self, on: { o, a in o.authorID == a.id }).select { o, a in (o.label, a.name) })
                    #expect(joined.map(\.0) == ["renamed"] && joined.map(\.1) == ["Ada"])
                    #expect(try await repo.count(SchemaOrder.all) == 1)
                    for try await publicRows in try await repo.execute(#"SELECT count(*)::int FROM public."order""#).decode(Int.self) {
                        #expect(publicRows == 0, "the search_path table must be untouched")
                    }
                    try await repo.delete(changed)
                    #expect(try await repo.count(SchemaOrder.all) == 0)
                } catch {
                    failure = error
                }
                try await repo.execute(#"DROP SCHEMA "Mixed Schema" CASCADE"#)
                try await repo.execute(#"DROP TABLE public."order""#)
                if let failure { throw failure }
            }
        }
    }
}
