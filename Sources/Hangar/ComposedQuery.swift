import PostgresNIO

// An arbitrary-width joined query, built imperatively instead of typed at
// every arity. `JoinedQuery`/`JoinedQuery3` fix the join count in the
// type itself (`JoinedQuery<A, B, Result>`, `JoinedQuery3<A, B, C, Result>`),
// which means a fourth or fifth table needs a new struct and a full
// duplicate method surface, and every composition closure downstream
// takes one positional argument per table — keeping track of which
// position is which table is exactly the ergonomics problem this exists
// to fix.
//
// The insight this leans on: `SQLExpression`/`Predicate`/`OrderTerm`
// already carry only table/column *name strings* (see `Column.swift`,
// `Predicate.swift`) — nothing about rendering needs the joined Swift
// type once its ON-predicate is built. So the query value this produces,
// `ComposedQuery<Base, Result>`, only ever has two type parameters
// regardless of how many tables it joins; the join list is a plain
// array of erased clauses. What stays fully typed is the *builder*:
// `QueryBuilder.join(_:on:)` hands back the joined table's real
// `QueryColumns`, aliased, as an ordinary Swift value — so composing five
// joins reads as five `let` bindings, and every later predicate/select
// closure refers to them by name instead of by position.
//
// One thing does not survive erasure and so is captured eagerly at
// `join` time: whether the joined table is soft-deletable, and under
// which column. Without it the query could not apply the deleted-row
// scope to a joined source, which is precisely the hole the fixed-arity
// forms had.

/// One joined table in a `ComposedQuery`, fully erased — see the file
/// comment for why that's safe.
struct ComposedJoin: Sendable {
    let kind: JoinKind
    /// Quoted table name, e.g. `"customers"`.
    let quotedTableName: String
    /// This join's alias, unquoted (`"t1"`, not `"\"t1\""`) — quoted at
    /// render time like every other identifier.
    let alias: String
    let onExpression: SQLExpression
    /// The joined table's `@Deleted` column, when it has one — read off
    /// its schema while the type is still known.
    let deletedAt: ColumnDefinition?

    /// The ON expression with this source's deleted-row condition ANDed
    /// on, under `scope`.
    ///
    /// It belongs in ON rather than WHERE: in WHERE it would discard the
    /// unmatched rows a LEFT JOIN exists to keep, quietly turning the
    /// outer join into an inner one. For an inner join the two placements
    /// are equivalent, so one rule covers both.
    func effectiveOnExpression(under scope: DeletedRowScope) -> SQLExpression {
        let condition = scope.forJoinedSource.condition(for: deletedAt, qualifiedBy: alias)
        return andedExpressions(onExpression, condition) ?? onExpression
    }
}

/// A query over `Base`, joined to however many other tables
/// `Table.query { }`'s closure called `q.join`/`q.leftJoin` on. Still a
/// value — nothing executes until a `Repo` runs it, exactly like `Query`
/// and `JoinedQuery`.
public struct ComposedQuery<Base: Table, Result: Sendable>: Sendable {
    let baseAlias: String
    var joins: [ComposedJoin]
    var predicate: Predicate?
    var orderings: [OrderTerm] = []
    var grouping: [SQLExpression] = []
    var having: Predicate?
    var rowLimit: Int?
    var rowOffset: Int?
    var isDistinct = false
    var distinctOn: [SQLExpression] = []
    var rowLock: RowLock?
    /// Which base rows this query sees when `Base` is soft-deletable;
    /// joined sources follow ``DeletedRowScope/forJoinedSource``.
    var deletedRows: DeletedRowScope = .excluded
    /// Preloads apply on the base-entity path only — a projection carries
    /// no models to hang associations on, so `QueryBuilder.select` drops
    /// them rather than carrying a promise it would not keep.
    var preloads: [PreloadStep<Base>] = []
    var selection: Selection<Result>?

    init(baseAlias: String, joins: [ComposedJoin]) {
        self.baseAlias = baseAlias
        self.joins = joins
    }

    /// The caller's predicate plus the base source's soft-delete
    /// condition. Every read path renders from this, never from
    /// `predicate`.
    var effectivePredicate: Predicate? {
        andedPredicate(
            predicate,
            deletedRows.condition(for: Base.schema.deletedAt, qualifiedBy: baseAlias))
    }

    /// At most `count` rows — used internally by `Repo.one` the same way
    /// `JoinedQuery`'s does; not chained after `select` by callers since
    /// `QueryBuilder.limit(_:)` is where this belongs while composing.
    func limited(_ count: Int) -> ComposedQuery<Base, Result> {
        var next = self
        next.rowLimit = count
        return next
    }
}

/// The mutable context `Table.query { q, base in ... }` hands to its closure.
/// Never escapes the closure and is never touched concurrently, so it
/// carries no `Sendable` conformance at all — there is nothing to check.
public final class QueryBuilder<Base: Table> {
    private static var baseAliasName: String { "t0" }
    private var joins: [ComposedJoin] = []
    private var predicate: Predicate?
    private var orderings: [OrderTerm] = []
    private var grouping: [SQLExpression] = []
    private var having: Predicate?
    private var rowLimit: Int?
    private var rowOffset: Int?
    private var isDistinct = false
    private var distinctOn: [SQLExpression] = []
    private var rowLock: RowLock?
    private var deletedRows: DeletedRowScope = .excluded
    private var preloads: [PreloadStep<Base>] = []
    private var nextAliasIndex = 1
    /// Set by the first `query()`/`select` call. `assembled()` snapshots
    /// the builder, so a mutation after that point would change nothing
    /// about the query already produced — see ``checkNotConsumed(_:)``.
    private var consumed = false

    /// `Base`'s own columns, qualified with this query's own alias —
    /// needed because every other table in the query is also aliased, so
    /// the base has to be too or a self-join back to it would collide.
    public var base: Base.QueryColumns { Base.QueryColumns(table: Self.baseAliasName) }

    /// Inner-joins `type`, minting a fresh alias nothing else in this
    /// query can collide with, and returns that table's columns under it.
    /// Joining the same type twice, or joining `Base` back to itself, is
    /// ordinary — the fresh alias is what a manual `.alias("t3")` call
    /// bought on `JoinedQuery`, done automatically here every time.
    @discardableResult
    public func join<T: Table>(
        _ type: T.Type, on condition: (T.QueryColumns) -> some PredicateConvertible
    ) -> T.QueryColumns {
        addJoin(.inner, type, condition)
    }

    /// `LEFT JOIN` — every row of the query so far, matched against
    /// `type` or not.
    @discardableResult
    public func leftJoin<T: Table>(
        _ type: T.Type, on condition: (T.QueryColumns) -> some PredicateConvertible
    ) -> T.QueryColumns {
        addJoin(.left, type, condition)
    }

    private func addJoin<T: Table>(
        _ kind: JoinKind, _ type: T.Type, _ condition: (T.QueryColumns) -> some PredicateConvertible
    ) -> T.QueryColumns {
        checkNotConsumed("join(\(T.self))")
        let alias = "t\(nextAliasIndex)"
        nextAliasIndex += 1
        let columns = T.QueryColumns(table: alias)
        let onPredicate = condition(columns).predicate
        joins.append(
            ComposedJoin(
                kind: kind, quotedTableName: T.schema.quotedName, alias: alias,
                onExpression: onPredicate.expression, deletedAt: T.schema.deletedAt))
        return columns
    }

    /// ANDs a condition onto the query — takes an already-built
    /// `Predicate`, not a closure, because every column it needs is
    /// already a local `let` from an earlier `q.join`/`q.base`.
    @discardableResult
    public func `where`(_ condition: some PredicateConvertible) -> QueryBuilder<Base> {
        checkNotConsumed("where")
        predicate = Self.combine(predicate, condition.predicate, "AND")
        return self
    }

    /// ORs a condition onto everything accumulated so far.
    @discardableResult
    public func orWhere(_ condition: some PredicateConvertible) -> QueryBuilder<Base> {
        checkNotConsumed("orWhere")
        predicate = Self.combine(predicate, condition.predicate, "OR")
        return self
    }

    /// Appends an ORDER BY term; chained calls order by multiple columns
    /// in call order.
    @discardableResult
    public func order(_ term: OrderTerm) -> QueryBuilder<Base> {
        checkNotConsumed("order")
        orderings.append(term)
        return self
    }

    /// Appends GROUP BY columns — any arity in one call, mixed types
    /// included (`q.groupBy(post.id, post.title, author.name)` groups by a
    /// `Column<UUID>` and two `Column<String>`s together). A single column
    /// still reads as `q.groupBy(post.id)`; this one signature covers both,
    /// the same way `select`'s pack signature covers every arity without a
    /// separate one-column overload. A later call (or a later step in one
    /// chain) appends more columns rather than replacing earlier ones.
    @discardableResult
    public func groupBy<each V>(_ columns: repeat Column<each V>) -> QueryBuilder<Base> {
        checkNotConsumed("groupBy")
        for column in repeat each columns {
            grouping.append(column.expression)
        }
        return self
    }

    /// ANDs a HAVING condition — the post-grouping filter.
    @discardableResult
    public func having(_ condition: some HavingConvertible) -> QueryBuilder<Base> {
        checkNotConsumed("having")
        having = Self.combine(having, condition._havingPredicate, "AND")
        return self
    }

    /// At most `count` rows; a later call replaces an earlier one.
    @discardableResult
    public func limit(_ count: Int) -> QueryBuilder<Base> {
        checkNotConsumed("limit")
        rowLimit = count
        return self
    }

    /// Skips `count` rows; pair with `order` for stable pagination.
    @discardableResult
    public func offset(_ count: Int) -> QueryBuilder<Base> {
        checkNotConsumed("offset")
        rowOffset = count
        return self
    }

    /// `SELECT DISTINCT` — mutually exclusive with `distinct(on:)`,
    /// whichever was called last wins.
    @discardableResult
    public func distinct() -> QueryBuilder<Base> {
        checkNotConsumed("distinct")
        isDistinct = true
        distinctOn = []
        return self
    }

    /// `SELECT DISTINCT ON (column, ...)`.
    @discardableResult
    public func distinct<V>(on column: Column<V>) -> QueryBuilder<Base> {
        checkNotConsumed("distinct(on:)")
        distinctOn.append(column.expression)
        isDistinct = false
        return self
    }

    /// `SELECT ... FOR UPDATE`, waiting, failing, or skipping at rows
    /// someone else holds — see ``Query/lockForUpdate(wait:)``.
    @discardableResult
    public func lockForUpdate(wait: RowLockWait = .wait) -> QueryBuilder<Base> {
        lock(.update, wait: wait)
    }

    /// `SELECT ... FOR SHARE`.
    @discardableResult
    public func lockForShare(wait: RowLockWait = .wait) -> QueryBuilder<Base> {
        lock(.share, wait: wait)
    }

    /// A locking read at any of Postgres's four strengths.
    @discardableResult
    public func lock(_ strength: RowLockStrength, wait: RowLockWait = .wait) -> QueryBuilder<Base> {
        checkNotConsumed("lock")
        rowLock = RowLock(strength: strength, wait: wait)
        return self
    }

    /// Include soft-deleted rows — of the base entity and of every joined
    /// table alike, since this says "stop filtering on deletion here".
    @discardableResult
    public func withDeleted() -> QueryBuilder<Base> {
        checkNotConsumed("withDeleted")
        deletedRows = .included
        return self
    }

    /// Restrict the *base* entity to its soft-deleted rows. Joined tables
    /// still exclude their own — a trash view of files joins to live
    /// owners, not deleted ones.
    @discardableResult
    public func onlyDeleted() -> QueryBuilder<Base> {
        checkNotConsumed("onlyDeleted")
        deletedRows = .only
        return self
    }

    // MARK: Preloads

    /// Preloads a `@HasMany` association on the base entity, optionally
    /// tuning the child query — the same surface `Query.preload` has.
    ///
    /// Preloads run after the base rows decode, so they apply to
    /// ``query()`` and are dropped by either `select` shape: a projection
    /// has no models to hang associations on.
    @discardableResult
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Base, Loadable<[Child]>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> QueryBuilder<Base> {
        checkNotConsumed("preload")
        preloads.append(.hasMany(association, nested))
        return self
    }

    /// Preloads a `@BelongsTo` association with a non-optional foreign key.
    @discardableResult
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Base, Loadable<Child>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> QueryBuilder<Base> {
        checkNotConsumed("preload")
        preloads.append(
            .toOne(association) { (loader: _ToOneLoader<Base, Child>, parents, repo) in
                try await loader.run(&parents, repo, nested)
            })
        return self
    }

    /// Preloads a `@HasOne`, or a `@BelongsTo` over a nullable foreign key.
    @discardableResult
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Base, Loadable<Child?>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> QueryBuilder<Base> {
        checkNotConsumed("preload")
        preloads.append(
            .toOne(association) { (loader: _OptionalToOneLoader<Base, Child>, parents, repo) in
                try await loader.run(&parents, repo, nested)
            })
        return self
    }

    // MARK: Producing the query

    /// The unprojected query: every base-entity row the accumulated
    /// joins/predicate match, decoded as `Base` itself.
    public func query() -> ComposedQuery<Base, Base> {
        assembled(carryingPreloads: true)
    }

    /// Typed multi-column projection — the same parameter-pack surface as
    /// `Query.select`/`JoinedQuery.select`, just with no closure argument
    /// to thread through: every column referenced is already a captured
    /// local.
    public func select<each S: Selectable>(
        _ build: () -> (repeat each S)
    ) -> ComposedQuery<Base, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build()
        var items: [(expression: SQLExpression, alias: String?)] = []
        for item in repeat each selected {
            items.append((item._selectFragment.expression, nil))
        }
        let expected = items.count
        let table = Base.schema.name
        return assembled(
            selection: Selection(items: items, invalid: nil) { row in
                let cells = row.makeRandomAccess()
                try _checkColumnCount(cells.count, expected: expected, table: table)
                var index = 0
                func next<V: PostgresDecodable>(_ type: V.Type) throws -> V {
                    defer { index += 1 }
                    return try _decodeColumn(
                        V.self, from: cells[index], table: table, column: "#\(index)")
                }
                return (repeat try next((each S).Value.self))
            })
    }

    /// Projection into a named `Decodable` type — the design's own
    /// example. The closure returns a **labeled** tuple; each label
    /// becomes the column's SQL alias and the key `T` decodes by, exactly
    /// as `Query.select(into:)`/`JoinedQuery.select(into:)`.
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type, _ build: () -> Fields
    ) -> ComposedQuery<Base, T> {
        let fields = build()
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: Base.schema.name,
                        reason:
                            "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by."
                    )
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: Base.schema.name,
                        reason:
                            "select(into:) tuple element '\(label)' is not a column or aggregate expression."
                    )
                    break
                }
                items.append((selectable._selectFragment.expression, label))
            }
        } else {
            invalid = .invalidProjection(
                table: Base.schema.name,
                reason:
                    "select(into:) takes a labeled tuple of at least two columns/aggregates, e.g. { (id: order.id, total: item.quantity) }."
            )
        }
        return assembled(
            selection: Selection(items: items, invalid: invalid) { row in
                try T(from: ProjectionDecoder(row: row.makeRandomAccess(), table: Base.schema.name))
            })
    }

    /// The one snapshot point: every `query()`/`select` funnels through
    /// here, and the builder is marked consumed so a later mutation is a
    /// trap rather than a silent no-op.
    private func assembled<R>(
        selection: Selection<R>? = nil, carryingPreloads: Bool = false
    ) -> ComposedQuery<Base, R> {
        consumed = true
        var query = ComposedQuery<Base, R>(baseAlias: Self.baseAliasName, joins: joins)
        query.predicate = predicate
        query.orderings = orderings
        query.grouping = grouping
        query.having = having
        query.rowLimit = rowLimit
        query.rowOffset = rowOffset
        query.isDistinct = isDistinct
        query.distinctOn = distinctOn
        query.rowLock = rowLock
        query.deletedRows = deletedRows
        if carryingPreloads { query.preloads = preloads }
        query.selection = selection
        return query
    }

    /// Mutating the builder after it has produced a query would change
    /// nothing about that query — `assembled()` copies, it does not alias
    /// — so the mutation is a mistake with no observable effect, which is
    /// this package's definition of the worst kind of bug. Trapping is
    /// deliberate: it is a wiring error in the closure, deterministic and
    /// caught on the first run, not a runtime condition a caller could
    /// recover from.
    private func checkNotConsumed(_ operation: String) {
        precondition(
            !consumed,
            """
            Hangar: `\(operation)` was called on a \(Base.self) query builder after \
            it already produced a query. `q.query()`/`q.select` snapshot the builder, \
            so this change would be silently ignored — move it above the call that \
            produces the query.
            """)
    }

    private static func combine(_ existing: Predicate?, _ added: Predicate, _ op: String)
        -> Predicate
    {
        guard let existing else { return added }
        return Predicate(expression: .infix(op, existing.expression, added.expression))
    }
}

extension Table {
    /// Builds an arbitrary-width joined query imperatively: every
    /// `q.join` mints its own alias and hands back that table's typed
    /// columns as an ordinary Swift value, so composing several joins
    /// reads as a sequence of `let` bindings rather than a positional
    /// closure argument per table (`JoinedQuery3`'s `{ _, comment, author
    /// in ... }` shape) or manual `.alias("t3")` bookkeeping.
    ///
    /// ```swift
    /// let report = Order.query { q, order in
    ///     let customer = q.join(Customer.self) { $0.id == order.customerID }
    ///     let item = q.join(OrderItem.self) { $0.orderID == order.id }
    ///     q.where(customer.active)
    ///     return q.select(into: OrderReport.self) {
    ///         (id: order.id, customer: customer.name, quantity: item.quantity)
    ///     }
    /// }
    /// ```
    ///
    /// The closure's second parameter is `Base`'s own columns under this
    /// query's alias — exactly `q.base`, handed in up front so the common
    /// case doesn't need a `let order = q.base` line before it can be used.
    /// `q.base` is still there for a closure that wants to compute it at a
    /// different point instead; both give the same value.
    ///
    /// The closure must return a query built from the builder it was
    /// handed. Constraining it — rather than returning whatever the
    /// closure returns — is what keeps the builder itself from escaping
    /// the scope it is only safe inside, and it is also what lets the
    /// closure's return type be inferred, so no `q -> ComposedQuery<...>`
    /// annotation is needed at the call site.
    public static func query<R>(
        _ build: (QueryBuilder<Self>, Self.QueryColumns) -> ComposedQuery<Self, R>
    ) -> ComposedQuery<Self, R> {
        let builder = QueryBuilder<Self>()
        return build(builder, builder.base)
    }
}

// MARK: - Rendering

extension SQLRenderer {
    /// `FROM base AS t0 [LEFT] JOIN other AS t1 ON ... [LEFT] JOIN ... ON ...`.
    /// Every alias was minted fresh by `QueryBuilder`, so — unlike
    /// `JoinedQuery`'s two-table `joinFromClause` — there is no ambiguity
    /// case to guard against: collision is impossible by construction.
    static func fromClause<Base: Table, R>(
        _ query: ComposedQuery<Base, R>, writer: inout BindWriter
    ) -> String {
        var sql = "FROM \(Base.schema.quotedName) AS \(quote(query.baseAlias))"
        for join in query.joins {
            sql += " \(join.kind.rawValue) \(join.quotedTableName) AS \(quote(join.alias))"
            let on = join.effectiveOnExpression(under: query.deletedRows)
            sql += " ON \(render(on, writer: &writer))"
        }
        return sql
    }

    static func select<Base: Table, R>(_ query: ComposedQuery<Base, R>) -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        let sql = selectText(query, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func selectText<Base: Table, R>(
        _ query: ComposedQuery<Base, R>, writer: inout BindWriter, overrideList: String? = nil
    ) -> String {
        let list: String
        if let overrideList {
            list = overrideList
        } else if let selection = query.selection {
            list = selection.items
                .map { item in
                    let rendered = render(item.expression, writer: &writer)
                    return item.alias.map { "\(rendered) AS \(quote($0))" } ?? rendered
                }
                .joined(separator: ", ")
        } else {
            list = Base.schema.qualifiedSelectList(as: query.baseAlias)
        }
        var sql =
            "SELECT \(distinctClause(query.isDistinct, query.distinctOn, writer: &writer))\(list)"
        sql += " \(fromClause(query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        if !query.grouping.isEmpty {
            let terms = query.grouping.map { render($0, writer: &writer) }.joined(separator: ", ")
            sql += " GROUP BY \(terms)"
        }
        if let having = query.having {
            sql += " HAVING \(render(having.expression, writer: &writer))"
        }
        if !query.orderings.isEmpty {
            let terms = query.orderings
                .map { "\(quote($0.table)).\(quote($0.column)) \($0.clause)" }
                .joined(separator: ", ")
            sql += " ORDER BY \(terms)"
        }
        if let limit = query.rowLimit { sql += " LIMIT \(limit)" }
        if let offset = query.rowOffset { sql += " OFFSET \(offset)" }
        if let lock = query.rowLock { sql += " \(lock.sql)" }
        return sql
    }

    /// `SELECT count(*)` over the composed query, honoring the same clause
    /// rules the one- and two-table forms do: grouping, having, and both
    /// distinct forms change what a row is, so their presence counts
    /// through a subquery. With a one-to-many join and none of those, this
    /// counts matches, not distinct base rows — `q.distinct()` when base
    /// rows are what you mean.
    static func count<Base: Table, R>(_ query: ComposedQuery<Base, R>) -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if composedChangesWhatARowIs(query) {
            let stripped = composedCountable(query)
            let inner = selectText(
                stripped, writer: &writer,
                overrideList: composedCountingList(stripped, writer: &writer))
            return RenderedStatement(
                sql: "SELECT count(*) FROM (\(inner)) AS \(quote("hangar_count"))",
                binds: writer.binds)
        }
        var sql = "SELECT count(*) \(fromClause(query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `SELECT EXISTS (...)` over the composed query — same clause rules
    /// as ``count(_:)``; a HAVING can empty an otherwise-matching set.
    static func exists<Base: Table, R>(_ query: ComposedQuery<Base, R>) -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if composedChangesWhatARowIs(query) {
            let stripped = composedCountable(query)
            let inner = selectText(
                stripped, writer: &writer,
                overrideList: composedCountingList(stripped, writer: &writer))
            return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
        }
        var inner = "SELECT 1 \(fromClause(query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &inner, writer: &writer)
        return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
    }

    private static func composedChangesWhatARowIs<Base: Table, R>(
        _ query: ComposedQuery<Base, R>
    ) -> Bool {
        !query.grouping.isEmpty || query.having != nil || query.isDistinct
            || !query.distinctOn.isEmpty
    }

    private static func composedCountable<Base: Table, R>(
        _ query: ComposedQuery<Base, R>
    ) -> ComposedQuery<Base, R> {
        var stripped = query
        stripped.orderings = []
        stripped.rowLimit = nil
        stripped.rowOffset = nil
        stripped.preloads = []
        stripped.rowLock = nil
        return stripped
    }

    private static func composedCountingList<Base: Table, R>(
        _ query: ComposedQuery<Base, R>, writer: inout BindWriter
    ) -> String? {
        guard query.selection == nil, !query.grouping.isEmpty else { return nil }
        return query.grouping
            .map { render($0, writer: &writer) }
            .joined(separator: ", ")
    }
}

// MARK: - Execution

extension Repo {
    /// Base-entity fetch through a composed join: decodes `Base` rows,
    /// then runs any carried preloads.
    public func all<Base: Table>(_ query: ComposedQuery<Base, Base>) async throws -> [Base] {
        let sequence = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        var models: [Base] = []
        for try await row in sequence {
            models.append(try Base(from: row))
        }
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models
    }

    /// Runs a projected composed query, decoding each row as its
    /// `.select`/`.select(into:)` shape.
    public func all<Base: Table, R>(_ query: ComposedQuery<Base, R>) async throws -> [R] {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: Base.schema.name,
                reason:
                    "this composed query's Result is not \(Base.self) but no .select installed a projection — this is a Hangar bug."
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
    public func one<Base: Table>(_ query: ComposedQuery<Base, Base>) async throws -> Base? {
        let results = try await all(query.limited(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: Base.schema.name)
        }
        return results.first
    }

    /// At most one projected row; more than one throws `tooManyRows`.
    public func one<Base: Table, R>(_ query: ComposedQuery<Base, R>) async throws -> R? {
        let results: [R] = try await all(query.limited(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: Base.schema.name)
        }
        return results.first
    }

    /// How many composed-join rows match. Grouping, having, and distinct
    /// count through a subquery, exactly as the single- and two-table
    /// `count` do; with a one-to-many join and none of those, this counts
    /// matches, not distinct base rows.
    public func count<Base: Table, R>(_ query: ComposedQuery<Base, R>) async throws -> Int {
        let statement = SQLRenderer.count(query)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .read, operation: "count")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(
                Int.self, from: cells[0], table: Base.schema.name, column: "count")
        }
        throw HangarError.columnCountMismatch(table: Base.schema.name, expected: 1, got: 0)
    }

    /// Whether any composed-join row matches — same clause rules as
    /// `count`.
    public func exists<Base: Table, R>(_ query: ComposedQuery<Base, R>) async throws -> Bool {
        let statement = SQLRenderer.exists(query)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .read, operation: "exists")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(
                Bool.self, from: cells[0], table: Base.schema.name, column: "exists")
        }
        throw HangarError.columnCountMismatch(table: Base.schema.name, expected: 1, got: 0)
    }
}
