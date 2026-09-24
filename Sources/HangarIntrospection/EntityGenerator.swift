import Foundation

/// Turns an introspected table into `@Entity` source.
///
/// The output is meant to be committed and then edited — it is a starting
/// point, not a build artifact regenerated on every compile. Anything the
/// generator cannot decide safely becomes a comment naming the decision
/// rather than a guess, because generated code is the code people trust most
/// and read least.
public struct EntityGenerator: Sendable {
    public struct Options: Sendable {
        /// Property access level. Models crossing a module boundary need
        /// `public`; most do not.
        public var isPublic: Bool
        /// Conformances added to every generated type.
        public var conformances: [String]
        /// Treat a nullable timestamp with this name as the soft-delete
        /// column and mark it `@Deleted`.
        public var softDeleteColumnNames: Set<String>

        public init(
            isPublic: Bool = false,
            conformances: [String] = ["Sendable", "Equatable"],
            softDeleteColumnNames: Set<String> = ["deleted_at", "deletedAt"]
        ) {
            self.isPublic = isPublic
            self.conformances = conformances
            self.softDeleteColumnNames = softDeleteColumnNames
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Generates one file's worth of source for `table`.
    public func generate(_ table: IntrospectedTable) -> String {
        var lines: [String] = []
        let access = options.isPublic ? "public " : ""
        let typeName = TypeMapping.typeName(forTable: table.name)

        lines.append("// Generated from \(table.schema).\(table.name) by HangarIntrospection.")
        lines.append("// Reviewed and committed like any other source — edit freely.")
        lines.append("")
        lines.append("import Foundation")
        lines.append("import Hangar")
        lines.append("")

        // Once per enum type: a scalar and an array column may share one.
        var declared = Set<String>()
        for column in table.columns where column.isEnum && declared.insert(column.elementUdtName).inserted {
            lines.append(contentsOf: enumDeclaration(for: column, access: access))
            lines.append("")
        }

        let conformances = options.conformances.isEmpty
            ? "" : ": " + options.conformances.joined(separator: ", ")
        lines.append("@Entity(\"\(table.name)\")")
        lines.append("\(access)struct \(typeName)\(conformances) {")

        for column in table.columns {
            lines.append(contentsOf: property(for: column, access: access).map { "    " + $0 })
        }

        if !table.foreignKeys.isEmpty {
            lines.append("")
            lines.append("    // Foreign keys found on this table. Associations are not")
            lines.append("    // generated: the property name, the direction, and whether the")
            lines.append("    // other side wants a has-many are decisions only you can make.")
            for key in table.foreignKeys {
                // A composite key is read as its first column pair only, so
                // describing it as `a -> t.b` would name a constraint that
                // does not exist. Naming the gap is the honest output — the
                // same rule the unmappable-type TODO follows.
                guard !key.isComposite else {
                    let name = key.constraintName.map { " (\($0))" } ?? ""
                    lines.append(
                        "    // TODO: \(key.column) -> \(key.referencedTable).\(key.referencedColumn)"
                            + " is one pair of a \(key.columnCount)-column foreign key\(name).")
                    lines.append(
                        "    // Hangar reads the first pair only; write the association by hand.")
                    continue
                }
                let related = TypeMapping.typeName(forTable: key.referencedTable)
                lines.append(
                    "    //   \(key.column) -> \(key.referencedTable).\(key.referencedColumn)"
                        + "  e.g. @BelongsTo(foreignKey: \\\(typeName).\(TypeMapping.camelCase(key.column))) var \(TypeMapping.camelCase(TypeMapping.singular(key.referencedTable))): Loadable<\(related)>")
            }
        }

        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func enumDeclaration(for column: IntrospectedColumn, access: String) -> [String] {
        let name = TypeMapping.enumTypeName(for: column.elementUdtName)
        var lines = [
            "/// Generated from the Postgres enum `\(column.elementUdtName)`.",
            "\(access)enum \(name): String, PostgresEnum, Sendable, Equatable, Codable {",
        ]
        for label in column.enumLabels {
            let caseName = TypeMapping.camelCase(label)
            lines.append(
                caseName == label
                    ? "    case \(caseName)" : "    case \(caseName) = \"\(label)\"")
        }
        lines.append("}")
        return lines
    }

    private func property(for column: IntrospectedColumn, access: String) -> [String] {
        let propertyName = TypeMapping.camelCase(column.name)
        var lines: [String] = []

        guard let baseType = TypeMapping.swiftType(for: column) else {
            lines.append("// TODO: \(column.name) is \(column.udtName), which has no")
            lines.append("// safe Swift mapping here — give it a type and a ColumnCodable")
            lines.append("// conformance, or exclude it from the model.")
            return lines
        }

        if TypeMapping.needsJSONBAttention(column) {
            lines.append("// \(column.name) is \(column.udtName). It is typed as String so the")
            lines.append("// model compiles; replace it with a Codable type and mark it @JSONB.")
        }

        var attributes: [String] = []
        if column.isPrimaryKey {
            // A generated key is excluded from INSERTs and read back, which
            // is exactly what the database is telling us with a default.
            attributes.append(
                column.hasDefault || column.isIdentity ? "@ID(generated: true)" : "@ID")
        }
        if options.softDeleteColumnNames.contains(column.name), column.isNullable,
            baseType == "Date"
        {
            attributes.append("@Deleted")
        }
        if propertyName != column.name {
            attributes.append("@Column(\"\(column.name)\")")
        }

        let type = column.isNullable ? "\(baseType)?" : baseType
        let prefix = attributes.isEmpty ? "" : attributes.joined(separator: " ") + " "
        // `let` for the key, `var` for everything else: a primary key that
        // changes is a different row.
        let binding = column.isPrimaryKey ? "let" : "var"
        lines.append("\(prefix)\(access)\(binding) \(propertyName): \(type)")
        return lines
    }
}
