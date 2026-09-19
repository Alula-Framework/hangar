/// An immutable query value. Every operator returns a new
/// `Query`; nothing mutates. `Model` fixes which columns are addressable;
/// `Result` is what a row decodes to — always `Model` in Phase 1, changed by
/// `.select {}` when projections arrive (Phase 4).
public struct Query<Model: Table, Result: Sendable>: Sendable {
    var predicate: Predicate?
    var orderings: [OrderTerm] = []
    var rowLimit: Int?
    var rowOffset: Int?
    /// Pending association preloads, executed by `Repo.all` after
    /// the parent rows decode. Carried on the query, applied only when the
    /// query produces full models.
    var preloads: [PreloadStep<Model>] = []
    /// A derived table to read from instead of the entity's own: `FROM (…) AS
    /// "posts"`. Set by the set operations, which have no name to give the
    /// combination and no need for one — see `SetOperation.swift`.
    var fromDerived: (@Sendable (inout BindWriter) -> String)?
    /// GROUP BY expressions and the HAVING predicate.
    var grouping: [SQLExpression] = []
    var having: Predicate?
    var isDistinct = false
    var distinctOn: [SQLExpression] = []
    var rowLock: RowLock? = nil
    /// Which rows this query sees when the model is soft-deletable.
    var deletedRows: DeletedRowScope = .excluded
    /// Named subqueries rendered into a leading `WITH` clause, in order.
    var ctes: [CommonTableExpression] = []
    /// When set, the query reads `FROM "<name>" AS "<entity table>"`
    /// instead of from the entity's own table.
    var fromCTE: String?
    /// Installed by `.select {}`: the SELECT list plus the row
    /// decoder for `Result`. Nil means "whole model" — every schema column
    /// in order, decoded by the generated `init(from:)`.
    var selection: Selection<Result>?

    init() {}

    /// The projection pivot: a new query over the same clauses with a
    /// different `Result`. Preloads are deliberately dropped — projections
    /// don't carry models to hang associations on.
    func rebinding<NewResult>(to selection: Selection<NewResult>) -> Query<Model, NewResult> {
        var next = Query<Model, NewResult>()
        next.predicate = predicate
        next.orderings = orderings
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.grouping = grouping
        next.having = having
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        next.rowLock = rowLock
        // Carried, not dropped: a projection over `withDeleted()` must keep
        // seeing deleted rows. Losing it here would answer a different
        // question than the one asked, silently.
        next.deletedRows = deletedRows
        next.ctes = ctes
        next.fromCTE = fromCTE
        next.fromDerived = fromDerived
        next.selection = selection
        return next
    }
}

// MARK: - Entry points on the entity type

extension Table {
    /// The unfiltered query: `repo.all(Post.all)`.
    public static var all: Query<Self, Self> { Query() }

    /// `Self.where { }` — sugar for `all.where { }`.
    // swift-format's AmbiguousTrailingClosureOverload rule flags this pair, and
    // the ambiguity is the mechanism. This overload exists only to be selected
    // for an aggregate operand and refuse it with a message; the two are told
    // apart by the closure's return type, which is exactly the case the rule
    // warns about in general and the intent here.
    @available(
        *, unavailable,
        message: """
            Aggregate functions are not allowed in WHERE — Postgres rejects this. WHERE
            chooses the rows that feed the aggregate, so it cannot also read it. Group the
            rows and use HAVING instead: `.groupBy { $0.someColumn }.having { ... }`.
            """
    )
    public static func `where`(
        _ build: (QueryColumns) -> AggregatePredicate
    ) -> Query<Self, Self> {
        fatalError("unavailable")
    }

    public static func `where`(
        _ build: (QueryColumns) -> some PredicateConvertible
    ) -> Query<Self, Self> {
        all.where(build)
    }

    /// `Self.order { }` — sugar for `all.order { }`.
    public static func order(_ build: (QueryColumns) -> OrderTerm) -> Query<Self, Self> {
        all.order(build)
    }

    /// `Self.limit(n)` — sugar for `all.limit(n)`.
    public static func limit(_ count: Int) -> Query<Self, Self> {
        all.limit(count)
    }

    /// `Self.select { }` — sugar for `all.select { }`.
    public static func select<each S: Selectable>(
        _ build: (QueryColumns) -> (repeat each S)
    ) -> Query<Self, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        all.select(build)
    }

    /// `Self.select(into:)` — sugar for `all.select(into:)`.
    public static func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (QueryColumns) -> Fields
    ) -> Query<Self, T> {
        all.select(into: type, build)
    }

    /// `Self.groupBy { }` — sugar for `all.groupBy { }`.
    public static func groupBy<V>(_ build: (QueryColumns) -> Column<V>) -> Query<
        Self, Grouped<Self>
    > {
        all.groupBy(build)
    }

    /// `Self.distinct(on:)` — sugar for `all.distinct(on:)`.
    public static func distinct<V>(on build: (QueryColumns) -> Column<V>) -> Query<Self, Self> {
        all.distinct(on: build)
    }
}

// MARK: - Composition operators (the design — all pure)

extension Query {
    /// Adds a condition, AND-combined with any existing ones — chained
    /// `where` calls narrow the result, which is what makes conditional
    /// composition work.
    // swift-format's AmbiguousTrailingClosureOverload rule flags this pair, and
    // the ambiguity is the mechanism. This overload exists only to be selected
    // for an aggregate operand and refuse it with a message; the two are told
    // apart by the closure's return type, which is exactly the case the rule
    // warns about in general and the intent here.
    @available(
        *, unavailable,
        message: """
            Aggregate functions are not allowed in WHERE — Postgres rejects this. WHERE
            chooses the rows that feed the aggregate, so it cannot also read it. Group the
            rows and use HAVING instead: `.groupBy { $0.someColumn }.having { ... }`.
            """
    )
    public func `where`(
        _ build: (Model.QueryColumns) -> AggregatePredicate
    ) -> Query<Model, Result> {
        fatalError("unavailable")
    }

    public func `where`(
        _ build: (Model.QueryColumns) -> some PredicateConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(
                expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Adds a condition OR-combined with everything accumulated so far
    /// (Ecto's `or_where`): `(existing) OR (added)`.
    public func orWhere(
        _ build: (Model.QueryColumns) -> some PredicateConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(
                expression: .infix("OR", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Appends an ORDER BY term; chained calls order by multiple columns in
    /// call order.
    public func order(_ build: (Model.QueryColumns) -> OrderTerm) -> Query<Model, Result> {
        var next = self
        next.orderings.append(build(Model.queryColumns))
        return next
    }

    /// At most `count` rows; a later call replaces an earlier one.
    public func limit(_ count: Int) -> Query<Model, Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    /// `SELECT DISTINCT` — whole-row deduplication. Mutually exclusive
    /// with ``distinct(on:)``; whichever was called last wins, the same
    /// last-call-wins rule `limit` follows.
    public func distinct() -> Query<Model, Result> {
        var next = self
        next.isDistinct = true
        next.distinctOn = []
        return next
    }

    /// `SELECT DISTINCT ON (column, ...)` — one row per distinct value of
    /// the named columns, chosen by the query's `ORDER BY`:
    ///
    /// ```swift
    /// // The newest post per author:
    /// Post.distinct(on: { $0.authorID })
    ///     .order { $0.authorID.asc() }
    ///     .order { $0.createdAt.desc() }
    /// ```
    ///
    /// Postgres requires the `ORDER BY` to start with the `DISTINCT ON`
    /// columns when both are present, and rejects the statement loudly when
    /// it doesn't. Call again to add further columns; calling `distinct()`
    /// afterwards replaces this, last call wins.
    public func distinct<V>(on build: (Model.QueryColumns) -> Column<V>) -> Query<Model, Result> {
        var next = self
        next.distinctOn.append(build(Model.queryColumns).expression)
        next.isDistinct = false
        return next
    }

    /// Appends a GROUP BY column; chained calls group by several.
    public func groupBy<V>(_ build: (Model.QueryColumns) -> Column<V>) -> Query<
        Model, Grouped<Model>
    >
    where Result == Model {
        retypedForGrouping(adding: build(Model.queryColumns).expression)
    }

    /// Chaining a second grouping column onto an already-grouped query.
    public func groupBy<V>(_ build: (Model.QueryColumns) -> Column<V>) -> Query<
        Model, Grouped<Model>
    >
    where Result == Grouped<Model> {
        retypedForGrouping(adding: build(Model.queryColumns).expression)
    }

    /// Carries every clause across the `Result` change. There is no selection
    /// to carry: `groupBy` is only available before one is set, which is what
    /// keeps this from dropping a projection silently.
    private func retypedForGrouping(adding expression: SQLExpression)
        -> Query<Model, Grouped<Model>>
    {
        var next = Query<Model, Grouped<Model>>()
        next.predicate = predicate
        next.orderings = orderings
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.grouping = grouping + [expression]
        next.having = having
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        next.rowLock = rowLock
        next.deletedRows = deletedRows
        next.ctes = ctes
        next.fromCTE = fromCTE
        next.fromDerived = fromDerived
        return next
    }

    /// HAVING over aggregate expressions; chained calls AND-combine:
    /// `.groupBy { $0.authorID }.having { $0.viewCount.sum > 100 }`.
    public func having(
        _ build: (Model.QueryColumns) -> some HavingConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns)._havingPredicate
        if let existing = next.having {
            next.having = Predicate(
                expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.having = added
        }
        return next
    }

    // MARK: Projections — select changes Result

    /// Typed projection of one or more columns/aggregates. This is the
    ///  parameter-pack surface — one signature covers every arity:
    ///
    /// ```swift
    /// let ids:   [UUID]           = try await repo.all(Post.select { $0.id })
    /// let pairs: [(UUID, String)] = try await repo.all(Post.select { ($0.id, $0.title) })
    /// ```
    public func select<each S: Selectable>(
        _ build: (Model.QueryColumns) -> (repeat each S)
    ) -> Query<Model, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build(Model.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        for item in repeat each selected {
            items.append((item._selectFragment.expression, nil))
        }
        let expected = items.count
        let table = Model.schema.name
        return rebinding(
            to: Selection(items: items, invalid: nil) { row in
                let cells = row.makeRandomAccess()
                try _checkColumnCount(cells.count, expected: expected, table: table)
                var index = 0
                func next<T: PostgresDecodable>(_ type: T.Type) throws -> T {
                    defer { index += 1 }
                    return try _decodeColumn(
                        T.self, from: cells[index], table: table, column: "#\(index)")
                }
                return (repeat try next((each S).Value.self))
            })
    }

    /// Projection into a named `Decodable` type. The closure returns a
    /// **labeled** tuple; each label becomes the column's SQL alias and the
    /// key the type decodes by:
    ///
    /// ```swift
    /// struct PostCount: Decodable { let authorID: UUID; let posts: Int }
    /// Post.groupBy { $0.authorID }
    ///.select(into: PostCount.self) { (authorID: $0.authorID, posts: $0.id.count) }
    /// ```
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (Model.QueryColumns) -> Fields
    ) -> Query<Model, T> {
        let fields = build(Model.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: Model.schema.name,
                        reason:
                            "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by."
                    )
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: Model.schema.name,
                        reason:
                            "select(into:) tuple element '\(label)' is not a column or aggregate expression."
                    )
                    break
                }
                items.append((selectable._selectFragment.expression, label))
            }
        } else {
            invalid = .invalidProjection(
                table: Model.schema.name,
                reason:
                    "select(into:) takes a labeled tuple of at least two columns/aggregates, e.g. { (id: $0.id, total: $0.viewCount.sum()) }."
            )
        }
        return rebinding(
            to: Selection(items: items, invalid: invalid) { row in
                try T(
                    from: ProjectionDecoder(row: row.makeRandomAccess(), table: Model.schema.name))
            })
    }

    /// Skips `count` rows; pair with `order` for stable pagination.
    public func offset(_ count: Int) -> Query<Model, Result> {
        var next = self
        next.rowOffset = count
        return next
    }
}

// MARK: - Row locking

/// The row-locking clause of a locking read.
enum RowLock: String, Sendable {
    case update = "FOR UPDATE"
    case share = "FOR SHARE"
}

extension Query {
    /// `SELECT ... FOR UPDATE`: locks the matched rows against concurrent
    /// writes until the transaction ends.
    ///
    /// ```swift
    /// try await repo.transaction { tx in
    ///     let account = try await tx.one(Account.where { $0.id == id }.lockForUpdate())
    ///     // the row is ours until commit
    /// }
    /// ```
    ///
    /// A locking read is a write in intent, so it always runs on the
    /// primary, never a read replica — and it only *means* anything inside
    /// a transaction, since the lock ends when the transaction does.
    public func lockForUpdate() -> Query<Model, Result> {
        var next = self
        next.rowLock = .update
        return next
    }

    /// `SELECT ... FOR SHARE`: blocks concurrent writers of the matched
    /// rows but admits other share-locking readers.
    public func lockForShare() -> Query<Model, Result> {
        var next = self
        next.rowLock = .share
        return next
    }
}
