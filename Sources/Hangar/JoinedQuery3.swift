import Changesets
import PostgresNIO

// Three-table joins: `A join B join C`, produced by calling `.join`/
// `.leftJoin` on a two-table `JoinedQuery`. Same value semantics, same
// clause set, closures receive all three column sets.
//
// Deliberately ordinary generics rather than a parameter-pack
// generalization: a pack can be *declared* in a closure's parameter list in
// this Swift version, but a stored pack cannot be re-expanded into the call
// that invokes it (verified by a compile spike), so the pack form would
// compromise exactly the ergonomics — the on-closure — that matter most.
// Three tables is the stated need; a pack migration can arrive later as a
// source-compatible refactor if the language grows into it.

/// A three-table query: `A` joined to `B` joined to `C`. `Result` defaults
/// to `A`; `.select {}` changes it, exactly as on `Query`.
public struct JoinedQuery3<A: Table, B: Table, C: Table, Result: Sendable>: Sendable {
    var kind1: JoinKind
    var on1: Predicate
    var kind2: JoinKind
    var on2: Predicate
    var baseAlias: String? = nil
    var joinedAlias: String? = nil
    var thirdAlias: String? = nil
    var columnsA: A.QueryColumns = A.queryColumns
    var columnsB: B.QueryColumns = B.queryColumns
    var columnsC: C.QueryColumns = C.queryColumns
    var predicate: Predicate? = nil
    var orderings: [OrderTerm] = []
    var grouping: [SQLExpression] = []
    var having: Predicate? = nil
    var rowLimit: Int? = nil
    var rowOffset: Int? = nil
    var isDistinct = false
    var distinctOn: [SQLExpression] = []
    var rowLock: RowLock? = nil
    /// Which base rows this query sees when `A` is soft-deletable; `B` and
    /// `C` follow ``DeletedRowScope/forJoinedSource``.
    var deletedRows: DeletedRowScope = .excluded
    /// Preloads apply when `Result == A` (the base-entity path).
    var preloads: [PreloadStep<A>] = []
    var selection: Selection<Result>? = nil

    func rebinding<NewResult>(to selection: Selection<NewResult>) -> JoinedQuery3<A, B, C, NewResult> {
        var next = JoinedQuery3<A, B, C, NewResult>(
            kind1: kind1, on1: on1, kind2: kind2, on2: on2)
        next.baseAlias = baseAlias
        next.joinedAlias = joinedAlias
        next.thirdAlias = thirdAlias
        next.columnsA = columnsA
        next.columnsB = columnsB
        next.columnsC = columnsC
        next.predicate = predicate
        next.orderings = orderings
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        next.rowLock = rowLock
        // Carried for the same reason `Query.rebinding` carries it: a
        // projection over `withDeleted()` must keep seeing deleted rows.
        next.deletedRows = deletedRows
        next.selection = selection
        return next
    }
}

// MARK: - Entry points (from a two-table join)

extension JoinedQuery {
    /// Joins a third table on — the closure sees all three column sets:
    ///
    /// ```swift
    /// Post.join(Comment.self, on: { p, c in c.postID == p.id })
    ///     .join(Author.self, on: { _, comment, author in comment.authorID == author.id })
    /// ```
    public func join<C: Table>(
        _ other: C.Type,
        on condition: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Predicate
    ) -> JoinedQuery3<A, B, C, A> where Result == A {
        joining(.inner, JoinSide<C>.plain, condition)
    }

    /// Joins a third, aliased table on — how a second self-join hop is
    /// named.
    public func join<C: Table>(
        _ other: Aliased<C>,
        on condition: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Predicate
    ) -> JoinedQuery3<A, B, C, A> where Result == A {
        joining(.inner, .aliased(other), condition)
    }

    /// Left-joins a third table on.
    public func leftJoin<C: Table>(
        _ other: C.Type,
        on condition: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Predicate
    ) -> JoinedQuery3<A, B, C, A> where Result == A {
        joining(.left, JoinSide<C>.plain, condition)
    }

    /// Left-joins a third, aliased table on.
    public func leftJoin<C: Table>(
        _ other: Aliased<C>,
        on condition: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Predicate
    ) -> JoinedQuery3<A, B, C, A> where Result == A {
        joining(.left, .aliased(other), condition)
    }

    private func joining<C: Table>(
        _ kind: JoinKind,
        _ third: JoinSide<C>,
        _ condition: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Predicate
    ) -> JoinedQuery3<A, B, C, A> where Result == A {
        var next = JoinedQuery3<A, B, C, A>(
            kind1: self.kind, on1: onPredicate,
            kind2: kind, on2: condition(columnsA, columnsB, third.columns))
        next.baseAlias = baseAlias
        next.joinedAlias = joinedAlias
        next.thirdAlias = third.alias
        next.columnsA = columnsA
        next.columnsB = columnsB
        next.columnsC = third.columns
        // Everything composed before the third join carries through —
        // composition order must not change the result.
        next.predicate = predicate
        next.orderings = orderings
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        next.distinctOn = distinctOn
        next.rowLock = rowLock
        next.deletedRows = deletedRows
        next.preloads = preloads
        return next
    }
}

// MARK: - Soft-delete scope

extension JoinedQuery3 {
    /// Include soft-deleted rows — of the base entity and of both joined
    /// tables alike.
    public func withDeleted() -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.deletedRows = .included
        return next
    }

    /// Restrict the *base* entity to its soft-deleted rows; the joined
    /// tables still exclude their own.
    public func onlyDeleted() -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.deletedRows = .only
        return next
    }

    /// The caller's predicate plus the base source's soft-delete condition.
    var effectivePredicate: Predicate? {
        andedPredicate(
            predicate,
            deletedRows.condition(
                for: A.schema.deletedAt, qualifiedBy: baseAlias ?? A.schema.name))
    }

    /// `on1` plus `B`'s soft-delete condition — in ON, not WHERE, so a
    /// LEFT JOIN keeps its unmatched rows.
    var effectiveOn1: Predicate {
        Self.scoped(on1, B.schema.deletedAt, joinedAlias ?? B.schema.name, deletedRows)
    }

    /// `on2` plus `C`'s soft-delete condition.
    var effectiveOn2: Predicate {
        Self.scoped(on2, C.schema.deletedAt, thirdAlias ?? C.schema.name, deletedRows)
    }

    private static func scoped(
        _ predicate: Predicate, _ column: ColumnDefinition?, _ qualifier: String,
        _ scope: DeletedRowScope
    ) -> Predicate {
        guard let condition = scope.forJoinedSource.condition(for: column, qualifiedBy: qualifier)
        else { return predicate }
        return Predicate(expression: .infix("AND", predicate.expression, condition))
    }
}

// MARK: - Composition (three-column-set closures)

extension JoinedQuery3 {
    /// ANDs a condition over all three tables onto the join.
    public func `where`(
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> some PredicateConvertible
    ) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        let added = build(columnsA, columnsB, columnsC).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Appends an ordering term; columns render table-qualified.
    public func order(
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> OrderTerm
    ) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.orderings.append(build(columnsA, columnsB, columnsC))
        return next
    }

    /// Appends a GROUP BY column from any of the three tables.
    public func groupBy<V>(
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Column<V>
    ) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.grouping.append(build(columnsA, columnsB, columnsC).expression)
        return next
    }

    /// ANDs a HAVING condition — the post-grouping filter.
    public func having(
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> some PredicateConvertible
    ) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        let added = build(columnsA, columnsB, columnsC).predicate
        if let existing = next.having {
            next.having = Predicate(expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.having = added
        }
        return next
    }

    /// At most `count` rows; a later call replaces an earlier one.
    public func limit(_ count: Int) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    /// Skips `count` rows; pair with `order` for stable pagination.
    public func offset(_ count: Int) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.rowOffset = count
        return next
    }

    /// `SELECT DISTINCT` — collapses join fan-out to distinct rows.
    /// Last-call-wins with `distinct(on:)`.
    public func distinct() -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.isDistinct = true
        next.distinctOn = []
        return next
    }

    /// `SELECT DISTINCT ON (...)` — same contract as the single-table form.
    public func distinct<V>(
        on build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Column<V>
    ) -> JoinedQuery3<A, B, C, Result> {
        var next = self
        next.distinctOn.append(build(columnsA, columnsB, columnsC).expression)
        next.isDistinct = false
        return next
    }

    /// Typed projection over all three tables — the same pack surface as
    /// single-table `select`.
    public func select<each S: Selectable>(
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> (repeat each S)
    ) -> JoinedQuery3<A, B, C, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build(columnsA, columnsB, columnsC)
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
                    return try _decodeColumn(T.self, from: cells[index], table: table, column: "#\(index)")
                }
                return (repeat try next((each S).Value.self))
            })
    }

    /// Projection into a named `Decodable` type over all three tables.
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (A.QueryColumns, B.QueryColumns, C.QueryColumns) -> Fields
    ) -> JoinedQuery3<A, B, C, T> {
        let fields = build(columnsA, columnsB, columnsC)
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason: "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by.")
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason: "select(into:) tuple element '\(label)' is not a column or aggregate expression.")
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
    /// `FROM a KIND b ON ... KIND c ON ...` with the three-way ambiguity
    /// guard — every FROM entry must expose a distinct name.
    static func joinFromClause<A, B, C, R>(
        _ query: JoinedQuery3<A, B, C, R>, writer: inout BindWriter
    ) throws -> String {
        let effective = [
            query.baseAlias ?? A.schema.name,
            query.joinedAlias ?? B.schema.name,
            query.thirdAlias ?? C.schema.name,
        ]
        guard Set(effective).count == 3 else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason: "the three joined tables must expose distinct names — alias the repeated one: \(A.schema.name).alias(\"a\") ... .join(\(C.schema.name).alias(\"c\"), on: ...).")
        }
        var sql = "FROM \(A.schema.quotedName)"
        if let alias = query.baseAlias { sql += " AS \(quote(alias))" }
        sql += " \(query.kind1.rawValue) \(B.schema.quotedName)"
        if let alias = query.joinedAlias { sql += " AS \(quote(alias))" }
        sql += " ON \(render(query.effectiveOn1.expression, writer: &writer))"
        sql += " \(query.kind2.rawValue) \(C.schema.quotedName)"
        if let alias = query.thirdAlias { sql += " AS \(quote(alias))" }
        sql += " ON \(render(query.effectiveOn2.expression, writer: &writer))"
        return sql
    }

    static func select<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        let sql = try selectText(query, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func selectText<A, B, C, R>(
        _ query: JoinedQuery3<A, B, C, R>, writer: inout BindWriter, overrideList: String? = nil
    ) throws -> String {
        let from = try joinFromClause(query, writer: &writer)
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
        } else if let alias = query.baseAlias {
            list = A.schema.qualifiedSelectList(as: alias)
        } else {
            list = A.schema.qualifiedSelectList
        }
        var sql = "SELECT \(distinctClause(query.isDistinct, query.distinctOn, writer: &writer))\(list)"
        sql += " \(from)"
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
        if let lock = query.rowLock { sql += " \(lock.rawValue)" }
        return sql
    }

    static func count<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if changesWhatARowIs3(query) {
            let stripped = countable3(query)
            let inner = try selectText(
                stripped, writer: &writer, overrideList: countingList3(stripped, writer: &writer))
            return RenderedStatement(
                sql: "SELECT count(*) FROM (\(inner)) AS \(quote("hangar_count"))",
                binds: writer.binds)
        }
        var sql = "SELECT count(*) \(try joinFromClause(query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func exists<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) throws -> RenderedStatement {
        var writer = BindWriter()
        writer.qualified = true
        if changesWhatARowIs3(query) {
            let stripped = countable3(query)
            let inner = try selectText(
                stripped, writer: &writer, overrideList: countingList3(stripped, writer: &writer))
            return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
        }
        var inner = "SELECT 1 \(try joinFromClause(query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &inner, writer: &writer)
        return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
    }

    private static func changesWhatARowIs3<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) -> Bool {
        !query.grouping.isEmpty || query.having != nil || query.isDistinct
            || !query.distinctOn.isEmpty
    }

    private static func countable3<A, B, C, R>(
        _ query: JoinedQuery3<A, B, C, R>
    ) -> JoinedQuery3<A, B, C, R> {
        var stripped = query
        stripped.orderings = []
        stripped.rowLimit = nil
        stripped.rowOffset = nil
        stripped.preloads = []
        stripped.rowLock = nil
        return stripped
    }

    private static func countingList3<A, B, C, R>(
        _ query: JoinedQuery3<A, B, C, R>, writer: inout BindWriter
    ) -> String? {
        guard query.selection == nil, !query.grouping.isEmpty else { return nil }
        return query.grouping
            .map { render($0, writer: &writer) }
            .joined(separator: ", ")
    }
}

// MARK: - Execution

extension Repo {
    /// Base-entity fetch through a three-table join: decodes `A` rows, then
    /// runs any carried preloads.
    public func all<A: Table, B: Table, C: Table>(
        _ query: JoinedQuery3<A, B, C, A>
    ) async throws -> [A] {
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

    /// Runs a projected three-table query, decoding each row as its
    /// `.select` shape.
    public func all<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) async throws -> [R] {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason: "the joined query's Result is not \(A.self) but no .select {} installed a projection — this is a Hangar bug.")
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
    public func one<A: Table, B: Table, C: Table>(
        _ query: JoinedQuery3<A, B, C, A>
    ) async throws -> A? {
        let results = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    /// At most one projected row; more than one throws `tooManyRows`.
    public func one<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) async throws -> R? {
        let results: [R] = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    /// How many joined rows match — same clause rules as the two-table
    /// `count`.
    public func count<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) async throws -> Int {
        let statement = try SQLRenderer.count(query)
        let sequence = try await execute(statement.postgresQuery(), intent: .read, operation: "count")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(Int.self, from: cells[0], table: A.schema.name, column: "count")
        }
        throw HangarError.columnCountMismatch(table: A.schema.name, expected: 1, got: 0)
    }

    /// Whether any joined row matches — same clause rules as `count`.
    public func exists<A, B, C, R>(_ query: JoinedQuery3<A, B, C, R>) async throws -> Bool {
        let statement = try SQLRenderer.exists(query)
        let sequence = try await execute(statement.postgresQuery(), intent: .read, operation: "exists")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(Bool.self, from: cells[0], table: A.schema.name, column: "exists")
        }
        throw HangarError.columnCountMismatch(table: A.schema.name, expected: 1, got: 0)
    }
}
