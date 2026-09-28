import Foundation

/// A column as the database describes it.
public struct IntrospectedColumn: Sendable, Equatable {
    /// The column's name as the catalogue stores it.
    public let name: String
    /// Postgres's own name for the type — `int4`, `text`, `_text` for an
    /// array of text, or the enum's type name.
    public let udtName: String
    /// Whether the column lacks a `NOT NULL` constraint.
    public let isNullable: Bool
    /// Whether the column is part of the table's primary key — one of
    /// several, for a composite key.
    public let isPrimaryKey: Bool
    /// Whether the database supplies a value when one is not given — a
    /// `DEFAULT`, a sequence, or an identity column. Such columns are
    /// excluded from INSERTs and read back, which is what `@ID(generated:)`
    /// expresses.
    public let hasDefault: Bool
    /// Whether the column is `GENERATED … AS IDENTITY`. An identity column
    /// also reports ``hasDefault``.
    public let isIdentity: Bool
    /// The enum's labels, when this column's type is a Postgres enum.
    public let enumLabels: [String]

    /// A column from its catalogue facts — for tests and hand-built input to
    /// ``EntityGenerator``.
    public init(
        name: String, udtName: String, isNullable: Bool, isPrimaryKey: Bool,
        hasDefault: Bool, isIdentity: Bool, enumLabels: [String] = []
    ) {
        self.name = name
        self.udtName = udtName
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.hasDefault = hasDefault
        self.isIdentity = isIdentity
        self.enumLabels = enumLabels
    }

    /// Whether the column is an array: Postgres names an array type after
    /// its element with a leading underscore.
    public var isArray: Bool { udtName.hasPrefix("_") }
    /// The type of one element: the column's own type, or for an array the
    /// element's (Postgres names `role[]` `_role`).
    public var elementUdtName: String { isArray ? String(udtName.dropFirst()) : udtName }
    /// Whether the column's type is a Postgres enum.
    public var isEnum: Bool { !enumLabels.isEmpty }
}

/// A foreign key, which is what an association is generated from.
public struct IntrospectedForeignKey: Sendable, Equatable {
    /// The referencing column in this table — the first, for a composite key.
    public let column: String
    /// The table the key points at.
    public let referencedTable: String
    /// The column `column` references in ``referencedTable``.
    public let referencedColumn: String
    /// How many columns the constraint spans. Anything above 1 is a
    /// composite key, of which only the first column pair is reported —
    /// see ``isComposite``.
    public let columnCount: Int
    /// The constraint's own name, so a composite key can be named in the
    /// generated comment rather than merely alluded to.
    public let constraintName: String?

    /// Whether this constraint spans more than one column pair. The
    /// introspector reads the first pair only, so describing a composite
    /// key as if it were `column -> table.column` would be a confident
    /// wrong answer — the generator says so instead.
    public var isComposite: Bool { columnCount > 1 }

    /// A foreign key from its catalogue facts.
    public init(
        column: String, referencedTable: String, referencedColumn: String,
        columnCount: Int = 1, constraintName: String? = nil
    ) {
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.columnCount = columnCount
        self.constraintName = constraintName
    }
}

/// One table, as read from the catalogue.
public struct IntrospectedTable: Sendable, Equatable {
    /// The table's name, unqualified.
    public let name: String
    /// The schema it lives in — `public` unless stated.
    public let schema: String
    /// Its columns, in the table's column order.
    public let columns: [IntrospectedColumn]
    /// Its foreign keys, one entry per constraint.
    public let foreignKeys: [IntrospectedForeignKey]

    /// A table from its parts — for tests and hand-built input to
    /// ``EntityGenerator``.
    public init(
        name: String, schema: String = "public",
        columns: [IntrospectedColumn], foreignKeys: [IntrospectedForeignKey] = []
    ) {
        self.name = name
        self.schema = schema
        self.columns = columns
        self.foreignKeys = foreignKeys
    }
}
