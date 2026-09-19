/// A typed reference to one table column — what `$0.title` is inside a
/// `where`/`order` closure. `Value` is the Swift property
/// type; operators are constrained on it, which is what makes
/// `Column<Int> > "x"` a compile error.
///
/// `Value` is deliberately unconstrained on the type itself: a `@JSONB`
/// column is a `Column<SomeCodable>` that simply has no comparison
/// operators until the JSONB operator set arrives (Phase 4/5).
public struct Column<Value>: Sendable {
    /// The column's name at the store (`view_count`, not `viewCount`).
    public let name: String
    /// The owning table — used only in scopes where a statement touches
    /// more than one table (correlated subqueries, joins); single-table
    /// SQL stays unqualified.
    public let table: String

    /// A column reference. `table` is the qualifier used in multi-table
    /// scopes — the table's own name normally, an alias under `Table.alias`.
    public init(_ name: String, table: String = "") {
        self.name = name
        self.table = table
    }

    var expression: SQLExpression { .column(table: table, name: name) }
}

// MARK: - Ordering

/// One ORDER BY term: `$0.publishedAt.desc`. Carries the
/// column's table for multi-table scopes; single-table SQL renders it bare.
public struct OrderTerm: Sendable {
    /// `ASC` or `DESC`.
    public enum Direction: String, Sendable {
        case asc = "ASC"
        case desc = "DESC"
    }

    /// Where NULLs sort relative to everything else.
    ///
    /// Absent means the server's default, which is not neutral: Postgres sorts
    /// NULLs *last* for `ASC` and *first* for `DESC`. That is the surprise this
    /// exists for — "newest first, but rows that never shipped at the bottom"
    /// is `.desc().nullsLast()`, and without it the unshipped rows lead.
    public enum NullsPlacement: String, Sendable {
        case first = "NULLS FIRST"
        case last = "NULLS LAST"
    }

    let table: String
    let column: String
    let direction: Direction
    var nulls: NullsPlacement?

    /// Everything after the column name: `ASC`, or `DESC NULLS LAST`.
    ///
    /// One property rather than the four copies of `direction.rawValue` this
    /// replaces — the two-table, three-table and composed join renderers each
    /// had their own, which is three places for a new clause to be forgotten.
    var clause: String {
        guard let nulls else { return direction.rawValue }
        return "\(direction.rawValue) \(nulls.rawValue)"
    }

    /// Built from schema metadata rather than a typed column — used by
    /// pagination to impose a deterministic order when the caller gave none.
    init(table: String, column: String, direction: Direction, nulls: NullsPlacement? = nil) {
        self.table = table
        self.column = column
        self.direction = direction
        self.nulls = nulls
    }

    /// Sort NULLs before every non-NULL value.
    public func nullsFirst() -> OrderTerm {
        var copy = self
        copy.nulls = .first
        return copy
    }

    /// Sort NULLs after every non-NULL value.
    public func nullsLast() -> OrderTerm {
        var copy = self
        copy.nulls = .last
        return copy
    }
}

extension Column {
    /// Order ascending by this column.
    public func asc() -> OrderTerm { OrderTerm(table: table, column: name, direction: .asc) }
    /// Order descending by this column.
    public func desc() -> OrderTerm { OrderTerm(table: table, column: name, direction: .desc) }
}
