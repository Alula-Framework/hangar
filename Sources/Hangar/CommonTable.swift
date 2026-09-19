import PostgresNIO

// A CTE as a value you build once and pass around.
//
// The name and the body travel together, which is the point: the old spelling
// took the name twice — once in `with("popular", as:)` and again in
// `reading(from: "popular")` — and nothing checked that they matched. A
// misspelling was a runtime error from Postgres about a relation that does not
// exist.
//
// The definition is a whole-row query (`Query<T, T>`) rather than a projection,
// and that is a guarantee rather than a limitation: a CTE read back as `T` has
// to expose `T`'s columns, and a projection would not. `select` on the
// *reference* side narrows what a reader takes out of it, which is where
// narrowing belongs.

/// A named common table expression over one entity.
///
/// Build it like a query, use it like a table:
///
/// ```swift
/// let popular = CommonTable<Post>("popular")
///     .where { $0.viewCount > 1_000 }
///     .order { $0.viewCount.desc() }
///     .limit(50)
///
/// Post.all
///     .with(popular)
///     .where { $0.authorID.in(popular.select { $0.authorID }) }
/// ```
public struct CommonTable<T: Table>: Sendable {
    /// The name this CTE is declared and referred to by.
    public let name: String
    /// What it selects — always whole rows of `T`.
    var definition: Query<T, T>

    /// An empty CTE over the whole table; narrow it with the builders below.
    public init(_ name: String) {
        self.name = name
        self.definition = T.all
    }

    private func mapping(_ transform: (Query<T, T>) -> Query<T, T>) -> CommonTable {
        var copy = self
        copy.definition = transform(definition)
        return copy
    }

    // MARK: - Building the body
    //
    // Forwarders, deliberately few: what a CTE body needs is what narrows a
    // set of rows. Grouping and projection change what the CTE *exposes*,
    // which would break reading it back as `T`, so they are absent by design
    // rather than by omission.

    /// Narrows the rows this CTE contains.
    public func `where`(
        _ build: (T.QueryColumns) -> some PredicateConvertible
    ) -> CommonTable {
        mapping { $0.where(build) }
    }

    /// Orders the rows inside the CTE — meaningful with `limit`.
    public func order(_ build: (T.QueryColumns) -> OrderTerm) -> CommonTable {
        mapping { $0.order(build) }
    }

    /// At most `count` rows.
    public func limit(_ count: Int) -> CommonTable {
        mapping { $0.limit(count) }
    }

    /// Skips `count` rows.
    public func offset(_ count: Int) -> CommonTable {
        mapping { $0.offset(count) }
    }

    /// Distinct rows.
    public func distinct() -> CommonTable {
        mapping { $0.distinct() }
    }

    // MARK: - Using it

    /// This CTE as a query — `FROM "<name>"`, reading back as `T`.
    public var all: Query<T, T> {
        T.all.reading(from: name)
    }

    /// One column of this CTE, for a membership test or a nested subquery.
    ///
    /// ```swift
    /// Post.where { $0.authorID.in(popular.select { $0.authorID }) }
    /// ```
    public func select<Value: PostgresDecodable & Sendable>(
        _ build: (T.QueryColumns) -> Column<Value>
    ) -> Query<T, Value> {
        all.select { columns in build(columns) }
    }
}

extension Query where Result == Model {
    /// Reads this query's rows from a CTE rather than the entity's table.
    ///
    /// The typed counterpart of ``Query/reading(from:)-(String)``: the name comes
    /// from the value, so it cannot disagree with the declaration.
    public func reading(from table: CommonTable<Model>) -> Query {
        reading(from: table.name)
    }
}

extension Query {
    /// Declares a CTE built elsewhere.
    ///
    /// The name comes from the value, so there is nothing to keep in sync.
    /// Declaring the same CTE twice keeps one declaration — a `WITH` list that
    /// names it twice is an error Postgres reports rather than a query.
    public func with<T>(_ table: CommonTable<T>) -> Query {
        guard !ctes.contains(where: { $0.name == table.name }) else { return self }
        var next = self
        let body = table.definition
        next.ctes.append(
            CommonTableExpression(
                name: table.name, isRecursive: false,
                body: .query { writer in SQLRenderer.selectText(body, writer: &writer) }))
        return next
    }
}
