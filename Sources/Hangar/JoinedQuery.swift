import Changesets
import PostgresNIO

// Joins. A joined query is still a value; its closures
// receive both tables' columns, and every column renders table-qualified
// because two tables share one namespace.
//
// Semantics follow Ecto: a join without a `.select {}` returns the *base*
// entity's rows (the join exists to filter or to feed aggregates);
// row pairs and cross-table shapes come from an explicit projection —
// which is what the design's  example does with `select(into:)`.

enum JoinKind: String, Sendable {
    case inner = "JOIN"
    case left = "LEFT JOIN"
}

/// A two-table query: `A` joined to `B`. `Result` defaults to `A`;
/// `.select {}` changes it, exactly as on `Query`.
public struct JoinedQuery<A: Table, B: Table, Result: Sendable>: Sendable {
    var kind: JoinKind
    var onPredicate: Predicate
    /// FROM-clause aliases; nil renders the bare table name. Set only by
    /// the `Aliased` entry points.
    var baseAlias: String? = nil
    var joinedAlias: String? = nil
    /// A CTE name to join *instead of* `B`'s table — the recursive step's
    /// `JOIN "tree"`, where the thing being joined has no table of its own.
    /// Rendered bare: a CTE is already the name, so there is nothing to alias.
    var joinedSource: String? = nil
    /// The column sets every composition closure receives — constructed at
    /// the join entry, so an aliased join's later `.where`/`.groupBy`
    /// closures see alias-qualified columns, not the frozen unaliased ones.
    var columnsA: A.QueryColumns = A.queryColumns
    var columnsB: B.QueryColumns = B.queryColumns
    var predicate: Predicate? = nil
    var orderings: [OrderTerm] = []
    var grouping: [SQLExpression] = []
    var having: Predicate? = nil
    var rowLimit: Int? = nil
    var rowOffset: Int? = nil
    var isDistinct = false
    var distinctOn: [SQLExpression] = []
    var rowLock: RowLock? = nil
    /// Which base rows this query sees when `A` is soft-deletable. Joined
    /// sources follow ``DeletedRowScope/forJoinedSource``; see
    /// ``effectiveOnPredicate``.
    var deletedRows: DeletedRowScope = .excluded
    /// Preloads apply when `Result == A` (the base-entity path).
    var preloads: [PreloadStep<A>] = []
    var selection: Selection<Result>? = nil

    func rebinding<NewResult>(to selection: Selection<NewResult>) -> JoinedQuery<A, B, NewResult> {
        var next = JoinedQuery<A, B, NewResult>(kind: kind, onPredicate: onPredicate)
        next.baseAlias = baseAlias
        next.joinedAlias = joinedAlias
        next.joinedSource = joinedSource
        next.columnsA = columnsA
        next.columnsB = columnsB
        next.predicate = predicate
        next.orderings = orderings
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        next.rowLock = rowLock
        // Carried, not dropped, for the same reason `Query.rebinding` carries
        // it: a projection over `withDeleted()` must keep seeing deleted rows.
        next.deletedRows = deletedRows
        next.selection = selection
        return next
    }
}

// MARK: - Entry points

/// One side of a join: a table, aliased or not. Internal currency that
/// lets every entry point funnel through one builder.
struct JoinSide<T: Table>: Sendable {
    let alias: String?
    let columns: T.QueryColumns

    static var plain: JoinSide<T> { JoinSide(alias: nil, columns: T.queryColumns) }
    static func aliased(_ source: Aliased<T>) -> JoinSide<T> {
        JoinSide(alias: source.name, columns: source.columns)
    }
}

/// The one builder every join entry point delegates to.
private func makeJoin<A: Table, B: Table>(
    _ kind: JoinKind,
    base: JoinSide<A>,
    other: JoinSide<B>,
    condition: (A.QueryColumns, B.QueryColumns) -> Predicate
) -> JoinedQuery<A, B, A> {
    var query = JoinedQuery<A, B, A>(
        kind: kind, onPredicate: condition(base.columns, other.columns))
    query.baseAlias = base.alias
    query.joinedAlias = other.alias
    query.columnsA = base.columns
    query.columnsB = other.columns
    return query
}

/// ``makeJoin(_:base:other:condition:)`` for a query that is already grouped:
/// same construction, a `Result` that still says the rows are collapsed.
private func makeGroupedJoin<A: Table, B: Table>(
    _ kind: JoinKind,
    base: JoinSide<A>,
    other: JoinSide<B>,
    condition: (A.QueryColumns, B.QueryColumns) -> Predicate
) -> JoinedQuery<A, B, Grouped<A>> {
    var query = JoinedQuery<A, B, Grouped<A>>(
        kind: kind, onPredicate: condition(base.columns, other.columns))
    query.baseAlias = base.alias
    query.joinedAlias = other.alias
    query.columnsA = base.columns
    query.columnsB = other.columns
    return query
}

extension Table {
    /// `FROM Self JOIN other ON...` — inner join; rows of `Self` that
    /// have a match.
    public static func join<B: Table>(
        _ other: B.Type,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        makeJoin(.inner, base: .plain, other: .plain, condition: condition)
    }

    /// Inner join against an aliased table — how the right-hand side of a
    /// self-join is named.
    public static func join<B: Table>(
        _ other: Aliased<B>,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        makeJoin(.inner, base: .plain, other: .aliased(other), condition: condition)
    }

    /// `FROM Self LEFT JOIN other ON...` — every row of `Self`, matched
    /// or not; the shape aggregates over optional children want.
    public static func leftJoin<B: Table>(
        _ other: B.Type,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        makeJoin(.left, base: .plain, other: .plain, condition: condition)
    }

    /// Left join against an aliased table.
    public static func leftJoin<B: Table>(
        _ other: Aliased<B>,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        makeJoin(.left, base: .plain, other: .aliased(other), condition: condition)
    }
}

extension Aliased {
    /// Inner join from an aliased base — the left half of a self-join:
    ///
    /// ```swift
    /// Employee.alias("manager").join(Employee.alias("report"),
    ///     on: { manager, report in report.managerID == manager.id })
    /// ```
    public func join<B: Table>(
        _ other: Aliased<B>,
        on condition: (T.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<T, B, T> {
        makeJoin(.inner, base: .aliased(self), other: .aliased(other), condition: condition)
    }

    /// Inner join from an aliased base onto a plainly-named table.
    public func join<B: Table>(
        _ other: B.Type,
        on condition: (T.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<T, B, T> {
        makeJoin(.inner, base: .aliased(self), other: .plain, condition: condition)
    }

    /// Left join from an aliased base.
    /// Left-joins another table onto an already-composed query;
    /// accumulated conditions, ordering, limits, and preloads carry over.
    /// Left join against an aliased table.
    public func leftJoin<B: Table>(
        _ other: Aliased<B>,
        on condition: (T.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<T, B, T> {
        makeJoin(.left, base: .aliased(self), other: .aliased(other), condition: condition)
    }

    /// Left join from an aliased base onto a plainly-named table.
    public func leftJoin<B: Table>(
        _ other: B.Type,
        on condition: (T.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<T, B, T> {
        makeJoin(.left, base: .aliased(self), other: .plain, condition: condition)
    }
}

extension Query {
    /// Joins another table onto an already-composed single-table query;
    /// accumulated conditions, ordering, limits, and preloads carry over.
    public func join<B: Table>(
        _ other: B.Type,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.inner, .plain, condition)
    }

    /// Joining an already-grouped query. Grouping survives composition into a
    /// join, so this is valid SQL; the result stays ``Grouped`` because the
    /// join does not un-collapse the rows.
    public func join<B: Table>(
        _ other: B.Type,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Grouped<Model>> where Result == Grouped<Model> {
        groupedJoin(.inner, .plain, condition)
    }

    /// The grouped counterpart of ``joined(_:_:_:)``.
    private func groupedJoin<B: Table>(
        _ kind: JoinKind,
        _ other: JoinSide<B>,
        _ condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Grouped<Model>> where Result == Grouped<Model> {
        var next: JoinedQuery<Model, B, Grouped<Model>> = makeGroupedJoin(
            kind, base: JoinSide<Model>.plain, other: other, condition: condition)
        next.predicate = predicate
        next.orderings = orderings
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.grouping = grouping
        next.having = having
        next.isDistinct = isDistinct
        next.deletedRows = deletedRows
        return next
    }

    /// Joins an aliased table onto an already-composed query — required
    /// when the joined table is the query's own (a self-join), allowed
    /// anywhere.
    public func join<B: Table>(
        _ other: Aliased<B>,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.inner, .aliased(other), condition)
    }

    /// Left-joins another table onto an already-composed query.
    public func leftJoin<B: Table>(
        _ other: B.Type,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.left, .plain, condition)
    }

    /// Left-joins an aliased table onto an already-composed query.
    public func leftJoin<B: Table>(
        _ other: Aliased<B>,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.left, .aliased(other), condition)
    }

    private func joined<B: Table>(
        _ kind: JoinKind,
        _ other: JoinSide<B>,
        _ condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Model> where Result == Model {
        var next = makeJoin(kind, base: JoinSide<Model>.plain, other: other, condition: condition)
        next.predicate = predicate
        next.orderings = orderings
        // Grouping and having were omitted here, so `Post.groupBy { … }.join(…)`
        // silently produced an ungrouped, unfiltered query — no error, just the
        // wrong rows. Composition order must not change the result.
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        // A lock composed before the join carries through — dropping it
        // silently would leave rows unlocked that the caller asked to lock.
        next.rowLock = rowLock
        // The deleted-row scope is a filter like any other: dropping it here
        // meant `StoredFile.onlyDeleted().join(...)` silently returned every
        // row, live ones included — an explicit scope inverted by composition.
        next.deletedRows = deletedRows
        next.preloads = preloads
        return next
    }
}

// MARK: - Soft-delete scope

extension JoinedQuery {
    /// Include soft-deleted rows — of the base entity and of the joined
    /// table alike, since this says "stop filtering on deletion here".
    public func withDeleted() -> JoinedQuery<A, B, Result> {
        var next = self
        next.deletedRows = .included
        return next
    }

    /// Restrict the *base* entity to its soft-deleted rows. The joined
    /// table still excludes its own — a trash view of files joins to live
    /// owners, not deleted ones.
    public func onlyDeleted() -> JoinedQuery<A, B, Result> {
        var next = self
        next.deletedRows = .only
        return next
    }

    /// The caller's predicate plus the base source's soft-delete condition,
    /// qualified with whatever name the base is addressed by.
    var effectivePredicate: Predicate? {
        andedPredicate(
            predicate,
            deletedRows.condition(
                for: A.schema.deletedAt, qualifiedBy: baseAlias ?? A.schema.name))
    }

    /// The ON condition plus the joined source's soft-delete condition.
    ///
    /// It belongs in ON rather than WHERE: in WHERE it would discard the
    /// unmatched rows a LEFT JOIN exists to keep, quietly turning the outer
    /// join into an inner one. For an inner join the two placements are
    /// equivalent, so one rule covers both.
    var effectiveOnPredicate: Predicate {
        guard
            let condition = deletedRows.forJoinedSource.condition(
                for: B.schema.deletedAt, qualifiedBy: joinedAlias ?? B.schema.name)
        else { return onPredicate }
        return Predicate(expression: .infix("AND", onPredicate.expression, condition))
    }
}

// MARK: - Composition (two-column-set closures)

extension JoinedQuery {
    /// ANDs a condition over both tables onto the join.
    public func `where`(
        _ build: (A.QueryColumns, B.QueryColumns) -> some PredicateConvertible
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        let added = build(columnsA, columnsB).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(
                expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Appends an ordering term; columns render table-qualified.
    public func order(
        _ build: (A.QueryColumns, B.QueryColumns) -> OrderTerm
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        next.orderings.append(build(columnsA, columnsB))
        return next
    }

    /// Appends a GROUP BY column from either table.
    public func groupBy<V>(
        _ build: (A.QueryColumns, B.QueryColumns) -> Column<V>
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        next.grouping.append(build(columnsA, columnsB).expression)
        return next
    }

    /// ANDs a HAVING condition — the post-grouping filter.
    public func having(
        _ build: (A.QueryColumns, B.QueryColumns) -> some HavingConvertible
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        let added = build(columnsA, columnsB)._havingPredicate
        if let existing = next.having {
            next.having = Predicate(
                expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.having = added
        }
        return next
    }

    /// At most `count` rows; a later call replaces an earlier one.
    public func limit(_ count: Int) -> JoinedQuery<A, B, Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    /// Skips `count` rows; pair with `order` for stable pagination.
    public func offset(_ count: Int) -> JoinedQuery<A, B, Result> {
        var next = self
        next.rowOffset = count
        return next
    }

    /// `SELECT DISTINCT` — collapses join fan-out to distinct rows.
    /// Last-call-wins with `distinct(on:)`.
    public func distinct() -> JoinedQuery<A, B, Result> {
        var next = self
        next.isDistinct = true
        next.distinctOn = []
        return next
    }

    /// `SELECT DISTINCT ON (...)` over the join — same contract as the
    /// single-table form.
    public func distinct<V>(
        on build: (A.QueryColumns, B.QueryColumns) -> Column<V>
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        next.distinctOn.append(build(columnsA, columnsB).expression)
        next.isDistinct = false
        return next
    }

    /// Typed projection over both tables — the same  pack surface as
    /// single-table `select`.
    public func select<each S: Selectable>(
        _ build: (A.QueryColumns, B.QueryColumns) -> (repeat each S)
    ) -> JoinedQuery<A, B, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build(columnsA, columnsB)
        var items: [(expression: SQLExpression, alias: String?)] = []
        for item in repeat each selected {
            items.append((item._selectFragment.expression, nil))
        }
        let expected = items.count
        let table = A.schema.name
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

    /// Projection into a named `Decodable` type over both tables — the
    /// design's  example:
    ///
    /// ```swift
    /// Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
    ///.groupBy { p, _ in p.id }
    ///.select(into: PostSummary.self) { p, c in
    ///         (id: p.id, title: p.title, commentCount: c.id.count)
    ///     }
    /// ```
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (A.QueryColumns, B.QueryColumns) -> Fields
    ) -> JoinedQuery<A, B, T> {
        let fields = build(columnsA, columnsB)
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason:
                            "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by."
                    )
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason:
                            "select(into:) tuple element '\(label)' is not a column or aggregate expression."
                    )
                    break
                }
                items.append((selectable._selectFragment.expression, label))
            }
        } else {
            invalid = .invalidProjection(
                table: A.schema.name,
                reason: "select(into:) takes a labeled tuple of at least two columns/aggregates.")
        }
        return rebinding(
            to: Selection(items: items, invalid: invalid) { row in
                try T(from: ProjectionDecoder(row: row.makeRandomAccess(), table: A.schema.name))
            })
    }
}

// MARK: - Rendering

extension SQLRenderer {
    /// `FROM a [AS alias] KIND b [AS alias] ON ...` — shared by select and
    /// count so alias handling and the ambiguity guard exist exactly once.
    static func joinFromClause<A, B, R>(
        _ query: JoinedQuery<A, B, R>, writer: inout BindWriter
    ) throws -> String {
        // The two FROM entries must expose distinct names or every column
        // reference in the statement is ambiguous. Aliases are how a
        // self-join satisfies this.
        let effectiveA = query.baseAlias ?? A.schema.name
        // A CTE's name is the name it joins under, so it distinguishes the
        // two sides exactly as an alias does — which is what makes joining an
        // entity to a CTE *over that same entity* legal rather than a
        // self-join without aliases.
        let effectiveB = query.joinedSource ?? query.joinedAlias ?? B.schema.name
        guard effectiveA != effectiveB else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason: A.schema.name == B.schema.name
                    ? "a self-join needs an alias on at least one side: \(A.schema.name).alias(\"parent\").join(\(B.schema.name).alias(\"child\"), on: ...)."
                    : "both sides of this join are named \"\(effectiveA)\" — give them distinct aliases."
            )
        }
        var sql = "FROM \(A.schema.quotedName)"
        if let alias = query.baseAlias { sql += " AS \(quote(alias))" }
        sql += " \(query.kind.rawValue) \(query.joinedSource.map(quote) ?? B.schema.quotedName)"
        if query.joinedSource == nil, let alias = query.joinedAlias {
            sql += " AS \(quote(alias))"
        }
        sql += " ON \(SQLRenderer.render(query.effectiveOnPredicate.expression, writer: &writer))"
        return sql
    }

    static func select<A, B, R>(_ query: JoinedQuery<A, B, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        let sql = try selectText(query, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// The full joined SELECT text — the entry point the count/exists
    /// subquery wrap reuses. `overrideList` substitutes the select list;
    /// see `countingList(for:)`.
    static func selectText<A, B, R>(
        _ query: JoinedQuery<A, B, R>, writer: inout BindWriter, overrideList: String? = nil
    ) throws -> String {
        let from = try joinFromClause(query, writer: &writer)
        let list: String
        if let overrideList {
            list = overrideList
        } else if let selection = query.selection {
            list = selection.items
                .map { item in
                    let rendered = SQLRenderer.render(item.expression, writer: &writer)
                    return item.alias.map { "\(rendered) AS \(quote($0))" } ?? rendered
                }
                .joined(separator: ", ")
        } else if let alias = query.baseAlias {
            // The base entity's columns under its alias — decoded by A's
            // positional decoder exactly as in a single-table fetch.
            list = A.schema.qualifiedSelectList(as: alias)
        } else {
            list = A.schema.qualifiedSelectList
        }
        var sql =
            "SELECT \(distinctClause(query.isDistinct, query.distinctOn, writer: &writer))\(list)"
        sql += " \(from)"
        SQLRenderer.appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        if !query.grouping.isEmpty {
            let terms = query.grouping.map { SQLRenderer.render($0, writer: &writer) }.joined(
                separator: ", ")
            sql += " GROUP BY \(terms)"
        }
        if let having = query.having {
            sql += " HAVING \(SQLRenderer.render(having.expression, writer: &writer))"
        }
        if !query.orderings.isEmpty {
            let terms = query.orderings
                .map { "\(quote($0.table)).\(quote($0.column)) \($0.clause)" }
                .joined(separator: ", ")
            sql += " ORDER BY \(terms)"
        }
        if let limit = query.rowLimit { sql += " LIMIT \(limit)" }
        if let offset = query.rowOffset { sql += " OFFSET \(offset)" }
        // Postgres itself rejects the invalid combinations loudly (FOR
        // UPDATE on the nullable side of an outer join, with GROUP BY...).
        if let lock = query.rowLock { sql += " \(lock.sql)" }
        return sql
    }

    /// `SELECT count(*)` over the joined query, honoring the same clause
    /// rules as the single-table form: grouping, having, and both distinct
    /// forms change what a row is, so their presence counts through a
    /// subquery. With a one-to-many join and none of those, this counts
    /// matches, not distinct base rows — `.distinct()` when base rows are
    /// what you mean.
    static func count<A, B, R>(_ query: JoinedQuery<A, B, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if joinedChangesWhatARowIs(query) {
            let stripped = countable(query)
            let inner = try selectText(
                stripped, writer: &writer,
                overrideList: joinedCountingList(stripped, writer: &writer))
            return RenderedStatement(
                sql: "SELECT count(*) FROM (\(inner)) AS \(quote("hangar_count"))",
                binds: writer.binds)
        }
        var sql = "SELECT count(*) \(try joinFromClause(query, writer: &writer))"
        SQLRenderer.appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `SELECT EXISTS (...)` over the joined query — same clause rules as
    /// ``count(_:)-``; a HAVING can empty an otherwise-matching set.
    static func exists<A, B, R>(_ query: JoinedQuery<A, B, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if joinedChangesWhatARowIs(query) {
            let stripped = countable(query)
            let inner = try selectText(
                stripped, writer: &writer,
                overrideList: joinedCountingList(stripped, writer: &writer))
            return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
        }
        var inner = "SELECT 1 \(try joinFromClause(query, writer: &writer))"
        SQLRenderer.appendWhere(query.effectivePredicate, to: &inner, writer: &writer)
        return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
    }

    private static func joinedChangesWhatARowIs<A, B, R>(_ query: JoinedQuery<A, B, R>) -> Bool {
        !query.grouping.isEmpty || query.having != nil || query.isDistinct
            || !query.distinctOn.isEmpty
    }

    private static func countable<A, B, R>(_ query: JoinedQuery<A, B, R>) -> JoinedQuery<A, B, R> {
        var stripped = query
        stripped.orderings = []
        stripped.rowLimit = nil
        stripped.rowOffset = nil
        stripped.preloads = []
        stripped.rowLock = nil
        return stripped
    }

    private static func joinedCountingList<A, B, R>(
        _ query: JoinedQuery<A, B, R>, writer: inout BindWriter
    ) -> String? {
        guard query.selection == nil, !query.grouping.isEmpty else { return nil }
        return query.grouping
            .map { SQLRenderer.render($0, writer: &writer) }
            .joined(separator: ", ")
    }
}

// MARK: - Execution

extension Repo {
    /// Base-entity fetch through a join: decodes `A` rows, then runs any
    /// carried preloads.
    public func all<A: Table, B: Table>(_ query: JoinedQuery<A, B, A>) async throws -> [A] {
        let sequence = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        var models: [A] = []
        for try await row in sequence {
            models.append(try A(from: row))
        }
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models
    }

    /// Runs a projected joined query, decoding each row as its `.select`
    /// shape.
    public func all<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> [R] {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason:
                    "the joined query's Result is not \(A.self) but no .select {} installed a projection — this is a Hangar bug."
            )
        }
        if let invalid = selection.invalid {
            throw invalid
        }
        let sequence = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        var results: [R] = []
        for try await row in sequence {
            results.append(try selection.decode(row))
        }
        return results
    }

    /// At most one base-entity row; more than one throws `tooManyRows`.
    public func one<A: Table, B: Table>(_ query: JoinedQuery<A, B, A>) async throws -> A? {
        let results = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    /// At most one projected row; more than one throws `tooManyRows`.
    public func one<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> R? {
        let results: [R] = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    /// How many joined rows match. Grouping, having, and distinct count
    /// through a subquery, exactly as the single-table `count` does; with a
    /// one-to-many join and none of those, this counts matches, not
    /// distinct base rows.
    public func count<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> Int {
        let statement = try SQLRenderer.count(query)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .read, operation: "count")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(
                Int.self, from: cells[0], table: A.schema.name, column: "count")
        }
        throw HangarError.columnCountMismatch(table: A.schema.name, expected: 1, got: 0)
    }

    /// Whether any joined row matches — same clause rules as `count`.
    public func exists<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> Bool {
        let statement = try SQLRenderer.exists(query)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .read, operation: "exists")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(
                Bool.self, from: cells[0], table: A.schema.name, column: "exists")
        }
        throw HangarError.columnCountMismatch(table: A.schema.name, expected: 1, got: 0)
    }

    private func quote(_ identifier: String) -> String {
        SQLRenderer.quote(identifier)
    }
}
