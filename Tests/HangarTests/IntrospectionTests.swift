import Foundation
import Testing

@testable import HangarIntrospection

/// Type mapping and code generation, with no database in the loop — the
/// introspector's queries need a server, but its decisions do not.
@Suite("Introspection: naming and type mapping")
struct TypeMappingTests {

    @Test("column names become camelCase, and are left alone when already so")
    func columnNaming() {
        #expect(TypeMapping.camelCase("created_at") == "createdAt")
        #expect(TypeMapping.camelCase("author_id") == "authorID" || TypeMapping.camelCase("author_id") == "authorId")
        #expect(TypeMapping.camelCase("title") == "title")
        // Not every schema is snake_case; a camelCase name must survive.
        #expect(TypeMapping.camelCase("createdAt") == "createdAt")
    }

    @Test("table names become singular type names")
    func tableNaming() {
        #expect(TypeMapping.typeName(forTable: "posts") == "Post")
        #expect(TypeMapping.typeName(forTable: "blog_posts") == "BlogPost")
        #expect(TypeMapping.typeName(forTable: "categories") == "Category")
        #expect(TypeMapping.typeName(forTable: "addresses") == "Address")
        // A word that is already singular must not be mangled.
        #expect(TypeMapping.typeName(forTable: "status") == "Status")
    }

    private func column(
        _ name: String, _ udt: String, nullable: Bool = false, pk: Bool = false,
        hasDefault: Bool = false, labels: [String] = []
    ) -> IntrospectedColumn {
        IntrospectedColumn(
            name: name, udtName: udt, isNullable: nullable, isPrimaryKey: pk,
            hasDefault: hasDefault, isIdentity: false, enumLabels: labels)
    }

    @Test("scalar types map to their Swift counterparts")
    func scalars() {
        #expect(TypeMapping.swiftType(for: column("a", "uuid")) == "UUID")
        #expect(TypeMapping.swiftType(for: column("a", "int8")) == "Int")
        #expect(TypeMapping.swiftType(for: column("a", "int4")) == "Int32")
        #expect(TypeMapping.swiftType(for: column("a", "text")) == "String")
        #expect(TypeMapping.swiftType(for: column("a", "timestamptz")) == "Date")
        #expect(TypeMapping.swiftType(for: column("a", "numeric")) == "Decimal")
        #expect(TypeMapping.swiftType(for: column("a", "bytea")) == "Data")
    }

    @Test("arrays map only where PostgresNIO can round-trip the element")
    func arrays() {
        #expect(TypeMapping.swiftType(for: column("a", "_text")) == "[String]")
        #expect(TypeMapping.swiftType(for: column("a", "_int8")) == "[Int]")
        // Decimal and Data have neither array conformance, so refusing beats
        // emitting a model that fails to decode at runtime.
        #expect(TypeMapping.swiftType(for: column("a", "_numeric")) == nil)
        #expect(TypeMapping.swiftType(for: column("a", "_bytea")) == nil)
    }

    @Test("an unknown type yields nothing rather than a guess")
    func unknownType() {
        #expect(TypeMapping.swiftType(for: column("a", "tsvector")) == nil)
        #expect(TypeMapping.swiftType(for: column("a", "geometry")) == nil)
    }
}

@Suite("Introspection: generated source")
struct EntityGeneratorTests {

    private func column(
        _ name: String, _ udt: String, nullable: Bool = false, pk: Bool = false,
        hasDefault: Bool = false, labels: [String] = []
    ) -> IntrospectedColumn {
        IntrospectedColumn(
            name: name, udtName: udt, isNullable: nullable, isPrimaryKey: pk,
            hasDefault: hasDefault, isIdentity: false, enumLabels: labels)
    }

    @Test("an ordinary table becomes an @Entity struct")
    func basicTable() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "blog_posts",
                columns: [
                    column("id", "uuid", pk: true, hasDefault: true),
                    column("title", "text"),
                    column("view_count", "int8"),
                    column("published_at", "timestamptz", nullable: true),
                ]))

        #expect(source.contains(#"@Entity("blog_posts")"#))
        #expect(source.contains("struct BlogPost: Sendable, Equatable {"))
        // A database-supplied key is generated, so it is excluded from INSERTs.
        #expect(source.contains("@ID(generated: true) let id: UUID"))
        #expect(source.contains("var title: String"))
        // The name differs from the column, so @Column carries the mapping.
        #expect(source.contains(#"@Column("view_count") var viewCount: Int"#))
        #expect(source.contains("var publishedAt: Date?"), "nullable becomes optional")
    }

    @Test("a key without a default is not marked generated")
    func nonGeneratedKey() {
        let source = EntityGenerator().generate(
            IntrospectedTable(name: "things", columns: [column("id", "uuid", pk: true)]))
        #expect(source.contains("@ID let id: UUID"))
        #expect(!source.contains("generated: true"))
    }

    @Test("a Postgres enum becomes a Swift enum beside the model")
    func enums() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "posts",
                columns: [
                    column("id", "uuid", pk: true),
                    column("status", "post_status", labels: ["draft", "published", "in_review"]),
                ]))

        #expect(source.contains("enum PostStatus: String, PostgresEnum"))
        #expect(source.contains("case draft"))
        // A label that is not a valid Swift identifier keeps its raw value.
        #expect(source.contains(#"case inReview = "in_review""#))
        #expect(source.contains("var status: PostStatus"))
    }

    @Test("a nullable deleted_at is wired for soft deletion")
    func softDelete() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "files",
                columns: [
                    column("id", "uuid", pk: true),
                    column("deleted_at", "timestamptz", nullable: true),
                ]))
        #expect(source.contains("@Deleted"))
        #expect(source.contains(#"@Column("deleted_at") var deletedAt: Date?"#))
    }

    @Test("a non-nullable deleted_at is not, because it could not mean 'live'")
    func softDeleteNeedsOptional() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "files",
                columns: [
                    column("id", "uuid", pk: true),
                    column("deleted_at", "timestamptz", nullable: false),
                ]))
        #expect(!source.contains("@Deleted"))
    }

    @Test("an unmappable column becomes a TODO, not a wrong type")
    func unmappableColumn() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "docs",
                columns: [column("id", "uuid", pk: true), column("body", "tsvector")]))
        #expect(source.contains("TODO"))
        #expect(source.contains("tsvector"))
        #expect(!source.contains("var body:"), "no guessed type")
    }

    @Test("jsonb compiles but says it wants a real type")
    func jsonb() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "docs",
                columns: [column("id", "uuid", pk: true), column("metadata", "jsonb")]))
        #expect(source.contains("var metadata: String"))
        #expect(source.contains("@JSONB"), "the comment must point at the real answer")
    }

    @Test("foreign keys are reported, not invented into associations")
    func foreignKeys() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "comments",
                columns: [column("id", "uuid", pk: true), column("post_id", "uuid")],
                foreignKeys: [
                    IntrospectedForeignKey(
                        column: "post_id", referencedTable: "posts", referencedColumn: "id")
                ]))
        // The direction and the property name are the author's call; the
        // generator surfaces the fact and shows the shape.
        #expect(source.contains("post_id -> posts.id"))
        #expect(source.contains("@BelongsTo"))
        // Shown as a suggestion, never emitted as a property: every line
        // mentioning the association is a comment.
        let associationLines = source.split(separator: "\n").filter { $0.contains("@BelongsTo") }
        #expect(!associationLines.isEmpty)
        #expect(associationLines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
    }

    @Test("a composite foreign key is refused, not described as a one-column one")
    func compositeForeignKey() {
        let source = EntityGenerator().generate(
            IntrospectedTable(
                name: "line_items",
                columns: [
                    column("id", "uuid", pk: true), column("order_id", "uuid"),
                    column("tenant_id", "uuid"),
                ],
                foreignKeys: [
                    IntrospectedForeignKey(
                        column: "order_id", referencedTable: "orders", referencedColumn: "id",
                        columnCount: 2, constraintName: "line_items_order_fkey")
                ]))
        // The catalogue read only ever sees the first column pair, so a
        // `@BelongsTo` suggestion here would name a key that isn't there.
        #expect(source.contains("TODO"))
        #expect(source.contains("2-column foreign key"))
        #expect(source.contains("line_items_order_fkey"))
        #expect(!source.contains("@BelongsTo"))
    }

    @Test("public models are opt-in")
    func accessLevel() {
        let table = IntrospectedTable(name: "posts", columns: [column("id", "uuid", pk: true)])
        #expect(!EntityGenerator().generate(table).contains("public struct"))
        #expect(
            EntityGenerator(options: .init(isPublic: true)).generate(table)
                .contains("public struct Post"))
    }
}

// Parallelized (testing plan, Phase 3) without needing a sandbox: these read
// `pg_catalog` definitions, not rows, so there was never anything to isolate —
// `withIntrospector` simply used to take the shared lock like everything else.
// `.serialized` dropped for the same reason. Assertions use `contains`, so they
// are unaffected by DDL another suite performs on its own tables.
@Suite(
    "Introspection against Postgres",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct SchemaIntrospectorTests {

    @Test("the fixture schema is read back with its real shapes")
    func readsFixtureSchema() async throws {
        try await withIntrospector { introspector in
            let tables = try await introspector.tables()
            let names = tables.map(\.name)
            #expect(names.contains("hangar_posts"))
            #expect(names.contains("hangar_files"))

            let posts = try #require(tables.first { $0.name == "hangar_posts" })

            // The primary key, and that the database supplies it.
            let id = try #require(posts.columns.first { $0.name == "id" })
            #expect(id.isPrimaryKey)
            #expect(id.hasDefault, "gen_random_uuid() is a default")
            #expect(id.udtName == "uuid")

            // Nullability read from the catalogue, not guessed.
            #expect(try #require(posts.columns.first { $0.name == "nickname" }).isNullable)
            #expect(!(try #require(posts.columns.first { $0.name == "title" }).isNullable))

            // The enum's labels come back in declaration order.
            let status = try #require(posts.columns.first { $0.name == "status" })
            #expect(status.isEnum)
            #expect(status.enumLabels == ["draft", "published", "archived"])
        }
    }

    @Test("foreign keys are discovered")
    func readsForeignKeys() async throws {
        try await withIntrospector { introspector in
            let tables = try await introspector.tables()
            let files = try #require(tables.first { $0.name == "hangar_files" })
            #expect(
                files.foreignKeys.contains {
                    $0.column == "owner_id" && $0.referencedTable == "hangar_authors"
                })
        }
    }

    @Test("generated source for a real table compiles in shape")
    func generatesFromLiveSchema() async throws {
        try await withIntrospector { introspector in
            let generated = try await introspector.generateEntities()
            let files = try #require(generated.first { $0.typeName == "HangarFile" })

            #expect(files.source.contains(#"@Entity("hangar_files")"#))
            #expect(files.source.contains("@ID let id: UUID"))
            // The soft-delete column is recognised from the live schema —
            // nullable timestamp, conventionally named.
            #expect(files.source.contains("@Deleted"))
            #expect(files.source.contains(#"@Column("deleted_at") var deletedAt: Date?"#))
        }
    }
}
