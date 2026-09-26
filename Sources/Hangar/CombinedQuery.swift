import PostgresNIO

// Set operations across entities, over projections (Relay #15).
//
// `Query.union` combines two queries of one entity's whole rows, which is how
// it guarantees the branches line up. A merged feed — timeline events,
// external events and audit entries as one list — is projections of three
// tables into one shape, and that is this:
//
//     let feed = TimelineEvent.all.select(into: FeedItem.self) { (id: $0.id, at: $0.at, kind: $0.kind) }
//         .unionAll(ExternalEvent.all.select(into: FeedItem.self) { (id: $0.id, at: $0.receivedAt, kind: $0.source) })
//         .order("at", .desc)
//         .limit(50)
//     let items = try await repo.all(feed)
//
// The branches must produce the same `Result`, which fixes their column
// types. Postgres lines columns up by *position*, not name, so a
// `select(into:)` branch whose labels come in a different order is
// reordered to match the first — otherwise `(id, at)` against `(at, id)`
// would put timestamps under `id`, or fail on the types. A branch whose
// labels are not the same set is refused before anything runs.

/// Two or more projections, of the same or different entities, combined by
/// `UNION`, `UNION ALL`, `INTERSECT` or `EXCEPT`. Built by
/// ``Query/union(_:)-(Query<Other,Result>)`` and its siblings; run with
/// ``Repo/all(_:)-(CombinedQuery<R>)``.
public struct CombinedQuery<Result: Sendable>: Sendable {
    struct Branch: Sendable {
        let render: @Sendable (inout BindWriter) -> String
        let ctes: [CommonTableExpression]
        /// What each output column is called: its alias, or a bare column's
        /// own name, or `nil` for an unnamed expression.
        let names: [String?]
    }

    var first: Branch
    var rest: [(SetOperator, Branch)] = []
    let decode: @Sendable (PostgresRow) throws -> Result
    var orderings: [(name: String, clause: String)] = []
    var rowLimit: Int?
    var rowOffset: Int?
    /// The first problem found while building; thrown when the query runs.
    var invalid: HangarError?
    let table: String

    /// The combination read as the next left-hand side: `UNION` and
    /// `EXCEPT` associate left, but `INTERSECT` binds tighter, so
    /// `a.union(b).intersect(c)` must render `((a) UNION (b)) INTERSECT (c)`
    /// to mean what it reads as.
    func adding<M, R>(_ op: SetOperator, _ query: Query<M, R>) -> CombinedQuery<Result> {
        var next = self
        let (branch, problem) = Self.branch(query, alignedTo: first.names)
        next.rest.append((op, branch))
        if next.invalid == nil { next.invalid = problem }
        return next
    }

    static func branch<M, R>(
        _ query: Query<M, R>, alignedTo names: [String?]?
    ) -> (Branch, HangarError?) {
        let table = M.schema.name
        var problem: HangarError?
        if query.rowLock != nil || query.lockedSetOperationBranch {
            problem = .rowLockOnSetOperation(table: table)
        }
        guard let selection = query.selection else {
            let branch = Branch(render: { _ in "" }, ctes: [], names: [])
            return (
                branch,
                problem
                    ?? .invalidProjection(
                        table: table,
                        reason:
                            "a set operation across entities combines projections — give every branch a .select { } or .select(into:) of the same shape"
                    )
            )
        }
        if let invalid = selection.invalid, problem == nil { problem = invalid }
        var items = selection.items
        if let names, names.allSatisfy({ $0 != nil }), items.allSatisfy({ $0.alias != nil }) {
            let byAlias = Dictionary(items.map { ($0.alias!, $0) }, uniquingKeysWith: { first, _ in first })
            let wanted = names.compactMap { $0 }
            if Set(byAlias.keys) == Set(wanted), byAlias.count == items.count {
                items = wanted.map { byAlias[$0]! }
            } else if problem == nil {
                problem = .invalidProjection(
                    table: table,
                    reason:
                        "this branch selects (\(items.compactMap(\.alias).joined(separator: ", "))) but the first selects (\(wanted.joined(separator: ", "))) — a set operation lines columns up by position, so every branch needs the same labels"
                )
            }
        }
        let aligned = items
        var withoutCTEs = query
        withoutCTEs.ctes = []
        let stripped = withoutCTEs
        let branchNames = aligned.map { item -> String? in
            if let alias = item.alias { return alias }
            if case .column(_, let name) = item.expression { return name }
            return nil
        }
        let branch = Branch(
            render: { writer in
                SQLRenderer.selectText(
                    stripped, writer: &writer,
                    overrideList: aligned.map { item in
                        let rendered = SQLRenderer.render(item.expression, writer: &writer)
                        return item.alias.map { "\(rendered) AS \(SQLRenderer.quote($0))" } ?? rendered
                    }.joined(separator: ", "))
            },
            ctes: query.ctes, names: branchNames)
        return (branch, problem)
    }

    init<M, R>(first query: Query<M, Result>, _ op: SetOperator, _ other: Query<R, Result>) {
        let (branch, problem) = Self.branch(query, alignedTo: nil)
        self.first = branch
        self.invalid = problem
        self.table = M.schema.name
        if let selection = query.selection {
            self.decode = selection.decode
        } else {
            // `invalid` already says why; this never runs.
            let table = M.schema.name
            self.decode = { @Sendable _ in
                throw HangarError.invalidProjection(table: table, reason: "no projection")
            }
        }
        let (second, secondProblem) = Self.branch(other, alignedTo: branch.names)
        self.rest = [(op, second)]
        if self.invalid == nil { self.invalid = secondProblem }
    }

    /// Adds `other`'s rows, removing duplicates across the whole combination.
    public func union<M: Table>(_ other: Query<M, Result>) -> CombinedQuery<Result> { adding(.union, other) }
    /// Adds `other`'s rows, keeping duplicates.
    public func unionAll<M: Table>(_ other: Query<M, Result>) -> CombinedQuery<Result> { adding(.unionAll, other) }
    /// Keeps the rows `other` also returns.
    public func intersect<M: Table>(_ other: Query<M, Result>) -> CombinedQuery<Result> { adding(.intersect, other) }
    /// Removes the rows `other` returns.
    public func except<M: Table>(_ other: Query<M, Result>) -> CombinedQuery<Result> { adding(.except, other) }

    /// Orders the combined rows by an output column — a `select(into:)`
    /// label, or a selected column's name. The name is checked against the
    /// first branch's columns and quoted; a name that is not one of them is
    /// ``HangarError/invalidProjection(table:reason:)`` when the query runs.
    public func order(
        _ column: String, _ direction: OrderTerm.Direction = .asc, nulls: OrderTerm.NullsPlacement? = nil
    ) -> CombinedQuery<Result> {
        var next = self
        if first.names.contains(column) {
            next.orderings.append((column, direction.rawValue + (nulls.map { " \($0.rawValue)" } ?? "")))
        } else if next.invalid == nil {
            next.invalid = .invalidProjection(
                table: table,
                reason:
                    "cannot order the combination by \"\(column)\": its columns are \(first.names.map { $0 ?? "(unnamed)" }.joined(separator: ", "))"
            )
        }
        return next
    }

    /// At most `count` of the combined rows.
    public func limit(_ count: Int) -> CombinedQuery<Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    /// Skips `count` of the combined rows; pair with `order`.
    public func offset(_ count: Int) -> CombinedQuery<Result> {
        var next = self
        next.rowOffset = count
        return next
    }

    func rendered() -> RenderedStatement {
        var writer = BindWriter()
        let ctes = ([first] + rest.map(\.1)).flatMap(\.ctes)
        var sql = SQLRenderer.withClause(ctes, writer: &writer)
        var combined = "(\(first.render(&writer)))"
        for (index, (op, branch)) in rest.enumerated() {
            if index > 0 { combined = "(\(combined))" }
            combined += " \(op.rawValue) (\(branch.render(&writer)))"
        }
        sql += combined
        if !orderings.isEmpty {
            sql += " ORDER BY " + orderings.map { "\(SQLRenderer.quote($0.name)) \($0.clause)" }.joined(separator: ", ")
        }
        if let rowLimit { sql += " LIMIT \(rowLimit)" }
        if let rowOffset { sql += " OFFSET \(rowOffset)" }
        var statement = RenderedStatement(sql: sql, binds: writer.binds)
        statement.invalid = invalid
        return statement
    }
}

extension Query {
    /// This projection's rows and `other`'s, duplicates removed — `other` may
    /// be a different entity, projected into the same `Result`.
    public func union<Other: Table>(_ other: Query<Other, Result>) -> CombinedQuery<Result> {
        CombinedQuery(first: self, .union, other)
    }

    /// This projection's rows and `other`'s, duplicates kept.
    public func unionAll<Other: Table>(_ other: Query<Other, Result>) -> CombinedQuery<Result> {
        CombinedQuery(first: self, .unionAll, other)
    }

    /// The rows both projections return.
    public func intersect<Other: Table>(_ other: Query<Other, Result>) -> CombinedQuery<Result> {
        CombinedQuery(first: self, .intersect, other)
    }

    /// This projection's rows that `other` does not return.
    public func except<Other: Table>(_ other: Query<Other, Result>) -> CombinedQuery<Result> {
        CombinedQuery(first: self, .except, other)
    }
}

extension Repo {
    /// Every row of a combination of projections.
    public func all<R>(_ query: CombinedQuery<R>) async throws -> [R] {
        let statement = query.rendered()
        if let invalid = statement.invalid { throw invalid }
        let sequence = try await execute(statement.postgresQuery(), intent: .read, operation: "select")
        var results: [R] = []
        for try await row in sequence {
            results.append(try query.decode(row))
        }
        return results
    }
}
