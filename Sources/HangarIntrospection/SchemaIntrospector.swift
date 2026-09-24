import Logging
import Foundation
import PostgresNIO

/// Reads a live database's catalogue.
///
/// Queries `pg_catalog` rather than `information_schema`: the standard views
/// are portable and lossy — they do not distinguish an array's element type,
/// name an enum's labels, or tell identity from default without extra joins.
/// Hangar is Postgres-only, so there is nothing to gain by pretending
/// otherwise.
public struct SchemaIntrospector: Sendable {
    private let client: PostgresClient
    private let logger: Logger?

    public init(client: PostgresClient, logger: Logger? = nil) {
        self.client = client
        self.logger = logger
    }

    /// Every ordinary table in `schema`, with its columns and foreign keys.
    ///
    /// Views, materialised views, and partitions are skipped: they are not
    /// things `@Entity` can insert into, and generating a model that cannot
    /// round-trip would be worse than generating nothing.
    public func tables(inSchema schema: String = "public") async throws -> [IntrospectedTable] {
        let enums = try await enumLabels()
        let keys = try await primaryKeyColumns(schema: schema)
        let foreignKeys = try await foreignKeys(schema: schema)

        var byTable: [String: [IntrospectedColumn]] = [:]
        let rows = try await client.query(
            """
            SELECT c.relname AS table_name,
                   a.attname AS column_name,
                   t.typname AS udt_name,
                   NOT a.attnotnull AS is_nullable,
                   (a.atthasdef OR a.attidentity <> '') AS has_default,
                   (a.attidentity <> '') AS is_identity
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid
            JOIN pg_type t ON t.oid = a.atttypid
            WHERE n.nspname = \(schema)
              AND c.relkind = 'r'
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY c.relname, a.attnum
            """, logger: logger ?? Self.quiet)

        for try await (table, column, udt, nullable, hasDefault, isIdentity) in rows.decode(
            (String, String, String, Bool, Bool, Bool).self)
        {
            byTable[table, default: []].append(
                IntrospectedColumn(
                    name: column, udtName: udt, isNullable: nullable,
                    isPrimaryKey: keys[table]?.contains(column) ?? false,
                    hasDefault: hasDefault, isIdentity: isIdentity,
                    // An enum array (`_role`) carries its element's labels.
                    enumLabels: enums[udt] ?? (udt.hasPrefix("_") ? enums[String(udt.dropFirst())] : nil) ?? []))
        }

        return byTable.keys.sorted().map { name in
            IntrospectedTable(
                name: name, schema: schema, columns: byTable[name] ?? [],
                foreignKeys: foreignKeys[name] ?? [])
        }
    }

    /// Generates a file per table.
    public func generateEntities(
        inSchema schema: String = "public",
        options: EntityGenerator.Options = .init()
    ) async throws -> [(typeName: String, source: String)] {
        let generator = EntityGenerator(options: options)
        return try await tables(inSchema: schema).map { table in
            (TypeMapping.typeName(forTable: table.name), generator.generate(table))
        }
    }

    // MARK: - Catalogue reads

    private func enumLabels() async throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let rows = try await client.query(
            """
            SELECT t.typname, e.enumlabel
            FROM pg_type t
            JOIN pg_enum e ON e.enumtypid = t.oid
            ORDER BY t.typname, e.enumsortorder
            """, logger: logger ?? Self.quiet)
        for try await (name, label) in rows.decode((String, String).self) {
            result[name, default: []].append(label)
        }
        return result
    }

    private func primaryKeyColumns(schema: String) async throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let rows = try await client.query(
            """
            SELECT c.relname, a.attname
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
            WHERE i.indisprimary AND n.nspname = \(schema)
            """, logger: logger ?? Self.quiet)
        for try await (table, column) in rows.decode((String, String).self) {
            result[table, default: []].insert(column)
        }
        return result
    }

    private func foreignKeys(schema: String) async throws -> [String: [IntrospectedForeignKey]] {
        var result: [String: [IntrospectedForeignKey]] = [:]
        let rows = try await client.query(
            """
            SELECT c.relname AS table_name,
                   a.attname AS column_name,
                   rc.relname AS referenced_table,
                   ra.attname AS referenced_column,
                   coalesce(array_length(con.conkey, 1), 1) AS column_count,
                   con.conname AS constraint_name
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class rc ON rc.oid = con.confrelid
            -- The FIRST column pair only. A composite foreign key spans
            -- several, and reading just this pair would describe a
            -- two-column key as a one-column one; `column_count` is
            -- carried so the generator can refuse rather than guess.
            JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
            JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = con.confkey[1]
            WHERE con.contype = 'f' AND n.nspname = \(schema)
            ORDER BY c.relname, a.attname
            """, logger: logger ?? Self.quiet)
        for try await (table, column, referenced, referencedColumn, columnCount, name) in
            rows.decode((String, String, String, String, Int, String).self)
        {
            result[table, default: []].append(
                IntrospectedForeignKey(
                    column: column, referencedTable: referenced,
                    referencedColumn: referencedColumn, columnCount: columnCount,
                    constraintName: name))
        }
        return result
    }

    private static let quiet = Logger(
        label: "hangar.introspection", factory: { _ in SwiftLogNoOpLogHandler() })
}
