import Changesets
import Foundation
import PostgresNIO

/// A rendered statement: SQL with `$n` placeholders plus the binds that fill
/// them, in placeholder order.
struct RenderedStatement {
    var sql: String
    var binds: [SQLBind]
}

extension RenderedStatement {
    /// The PostgresNIO query, with every bind applied. Throwing binds
    /// (JSONB encoding) surface here — before anything reaches the wire.
    func postgresQuery() throws -> PostgresQuery {
        var bindings = PostgresBindings(capacity: binds.count)
        for bind in binds {
            try bind.apply(&bindings)
        }
        return PostgresQuery(unsafeSQL: sql, binds: bindings)
    }
}

/// Collects binds and hands out `$n` placeholders in order — shared down
/// into subquery rendering so placeholder numbering stays consistent
/// across nesting.
struct BindWriter {
    var binds: [SQLBind] = []
    /// True inside multi-table scopes (correlated subqueries, joins):
    /// column references render `"table"."name"` instead of bare names.
    var qualified = false

    mutating func placeholder(_ bind: SQLBind) -> String {
        binds.append(bind)
        return "$\(binds.count)"
    }
}

/// A subquery's SQL, rendered lazily against the outer statement's writer
///: the payoff of owning the AST is that nesting needs no special
/// mechanism beyond sharing the placeholder counter.
struct SubquerySQL: Sendable {
    let render: @Sendable (inout BindWriter) -> String
}

/// AST → SQL text + ordered binds (the design, layer 3). Identifiers are
/// always double-quoted; values are always parameters. Column lists are
/// always explicit and in schema order — never `*` — which is what lets the
/// generated decoder consume cells positionally.
enum SQLRenderer {

    // MARK: Statements

    static func select<M, R>(_ query: Query<M, R>) -> RenderedStatement {
        var writer = BindWriter()
        let sql = selectText(query, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// The full SELECT statement text, appending binds to `writer` — the
    /// entry point subqueries reuse.
    static func selectText<M, R>(
        _ query: Query<M, R>, writer: inout BindWriter, overrideList: String? = nil
    ) -> String {
        let prefix = withClause(query.ctes, writer: &writer)
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
            list = M.schema.selectList
        }
        var sql =
            "\(prefix)SELECT \(distinctClause(query.isDistinct, query.distinctOn, writer: &writer))\(list) FROM \(source(M.self, query: query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        if !query.grouping.isEmpty {
            let terms = query.grouping
                .map { render($0, writer: &writer) }
                .joined(separator: ", ")
            sql += " GROUP BY \(terms)"
        }
        if let having = query.having {
            sql += " HAVING \(render(having.expression, writer: &writer))"
        }
        if !query.orderings.isEmpty {
            let terms = query.orderings
                .map { "\(quote($0.column)) \($0.clause)" }
                .joined(separator: ", ")
            sql += " ORDER BY \(terms)"
        }
        // LIMIT/OFFSET are validated Ints; rendered literally.
        if let limit = query.rowLimit { sql += " LIMIT \(limit)" }
        if let offset = query.rowOffset { sql += " OFFSET \(offset)" }
        if let lock = query.rowLock { sql += " \(lock.rawValue)" }
        return sql
    }

    /// `SELECT count(*)` over the query's predicate.
    ///
    /// Ordering, limit, and offset are deliberately ignored — `count` answers
    /// "how many match", and neither reordering nor paginating changes that.
    ///
    /// `GROUP BY`, `HAVING`, and `DISTINCT` are **not** ignored: each changes
    /// what a row *is*, so counting without them answers a different question
    /// than the one asked. When any is present the query is counted as a
    /// subquery, which is the only rendering that yields the number of rows
    /// the equivalent `all` would return.
    static func count<M, R>(_ query: Query<M, R>) -> RenderedStatement {
        var writer = BindWriter()
        if changesWhatARowIs(query) {
            let stripped = countableSubquery(of: query)
            let inner = selectText(
                stripped, writer: &writer,
                overrideList: countingList(for: stripped, writer: &writer))
            return RenderedStatement(
                sql: "SELECT count(*) FROM (\(inner)) AS \(quote("hangar_count"))",
                binds: writer.binds)
        }
        let prefix = withClause(query.ctes, writer: &writer)
        var sql = "\(prefix)SELECT count(*) FROM \(source(M.self, query: query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `SELECT EXISTS (...)`, honoring the same clauses as ``count(_:)``.
    ///
    /// A `HAVING` clause can empty an otherwise-matching set, so ignoring it
    /// would report `true` for a query that returns no rows.
    static func exists<M, R>(_ query: Query<M, R>) -> RenderedStatement {
        var writer = BindWriter()
        if changesWhatARowIs(query) {
            let stripped = countableSubquery(of: query)
            let inner = selectText(
                stripped, writer: &writer,
                overrideList: countingList(for: stripped, writer: &writer))
            return RenderedStatement(sql: "SELECT EXISTS (\(inner))", binds: writer.binds)
        }
        let prefix = withClause(query.ctes, writer: &writer)
        var inner = "SELECT 1 FROM \(source(M.self, query: query, writer: &writer))"
        appendWhere(query.effectivePredicate, to: &inner, writer: &writer)
        return RenderedStatement(sql: "\(prefix)SELECT EXISTS (\(inner))", binds: writer.binds)
    }

    /// `""`, `"DISTINCT "`, or `"DISTINCT ON (...) "` — shared by every
    /// select renderer.
    static func distinctClause(
        _ isDistinct: Bool, _ distinctOn: [SQLExpression], writer: inout BindWriter
    ) -> String {
        if !distinctOn.isEmpty {
            let terms = distinctOn.map { render($0, writer: &writer) }.joined(separator: ", ")
            return "DISTINCT ON (\(terms)) "
        }
        return isDistinct ? "DISTINCT " : ""
    }

    /// A valid inner select list for a counted subquery.
    ///
    /// A grouped query with no projection would otherwise render its full
    /// column list, which Postgres rejects — columns outside the GROUP BY
    /// cannot appear ungrouped. The grouping expressions themselves are the
    /// honest list: one row per group is exactly what is being counted.
    static func countingList<M, R>(
        for query: Query<M, R>, writer: inout BindWriter
    ) -> String? {
        guard query.selection == nil, !query.grouping.isEmpty else { return nil }
        return query.grouping
            .map { render($0, writer: &writer) }
            .joined(separator: ", ")
    }

    /// Whether the query carries a clause that changes what a row is, and so
    /// changes what counting one means.
    private static func changesWhatARowIs<M, R>(_ query: Query<M, R>) -> Bool {
        !query.grouping.isEmpty || query.having != nil || query.isDistinct
            || !query.distinctOn.isEmpty
    }

    /// The query stripped of clauses that cannot appear in a counted subquery
    /// and do not affect the count.
    ///
    /// `ORDER BY` is meaningless in this position and Postgres rejects it
    /// alongside some aggregates. `LIMIT`/`OFFSET` would change the number,
    /// but `count` answers "how many match", not "how many are on this page".
    private static func countableSubquery<M, R>(of query: Query<M, R>) -> Query<M, R> {
        var stripped = query
        stripped.orderings = []
        stripped.rowLimit = nil
        stripped.rowOffset = nil
        stripped.preloads = []
        // Counting must not lock the rows it counts — a lock inside a count
        // subquery would be a real, invisible side effect.
        stripped.rowLock = nil
        return stripped
    }

    /// `SELECT 1 FROM... WHERE...` for a correlated EXISTS predicate
    ///: rendered fully qualified, because the inner table's columns
    /// and the outer query's coexist in one scope.
    static func existsText<M, R>(_ query: Query<M, R>, writer: inout BindWriter) -> String {
        let wasQualified = writer.qualified
        writer.qualified = true
        defer { writer.qualified = wasQualified }
        var sql = "SELECT 1 FROM \(M.schema.quotedName)"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        return sql
    }

    static func insert<M: Table>(_ model: M) throws -> RenderedStatement {
        let schema = M.schema
        let columns = schema.insertable
        // Every column is database-generated: `()` would be a syntax error.
        guard !columns.isEmpty else {
            return RenderedStatement(
                sql: "INSERT INTO \(schema.quotedName) DEFAULT VALUES RETURNING \(schema.selectList)",
                binds: [])
        }
        var writer = BindWriter()
        let placeholders =
            try columns
            .map { writer.placeholder(try bind(model, $0.name, in: schema)) }
            .joined(separator: ", ")
        let sql = """
            INSERT INTO \(schema.quotedName) (\(schema.insertList)) \
            VALUES (\(placeholders)) RETURNING \(schema.selectList)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `INSERT INTO t (cols) VALUES (...), (...), ... RETURNING cols` —
    /// every model in one statement, one round trip.
    static func insert<M: Table>(_ models: [M]) throws -> RenderedStatement {
        let schema = M.schema
        let columns = schema.insertable
        // Every column is database-generated. `DEFAULT VALUES` inserts one
        // row, so name one generated column and give each row its default.
        if columns.isEmpty, let first = schema.columns.first {
            let rows = Array(repeating: "(DEFAULT)", count: models.count).joined(separator: ", ")
            return RenderedStatement(
                sql: "INSERT INTO \(schema.quotedName) (\(first.quotedName)) VALUES \(rows) RETURNING \(schema.selectList)",
                binds: [])
        }
        var writer = BindWriter()
        let rows =
            try models
            .map { model in
                let placeholders =
                    try columns
                    .map { writer.placeholder(try bind(model, $0.name, in: schema)) }
                    .joined(separator: ", ")
                return "(\(placeholders))"
            }
            .joined(separator: ", ")
        let sql = """
            INSERT INTO \(schema.quotedName) (\(schema.insertList)) \
            VALUES \(rows) RETURNING \(schema.selectList)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func update<M: Table>(_ model: M) throws -> RenderedStatement {
        let schema = M.schema
        let sets = schema.updatable
        guard !sets.isEmpty else {
            throw HangarError.noUpdatableColumns(table: schema.name)
        }
        var writer = BindWriter()
        let assignments =
            try sets
            .map {
                "\($0.quotedName) = \(writer.placeholder(try bind(model, $0.name, in: schema)))"
            }
            .joined(separator: ", ")
        let sql = """
            UPDATE \(schema.quotedName) SET \(assignments) \
            WHERE \(try primaryKeyClause(model, schema: schema, writer: &writer)) \
            RETURNING \(schema.selectList)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    // MARK: Changeset statements
    //
    // A changeset's write is *minimal*: only `changedFields` appear in the
    // column list / SET clause. Column order is schema order (filtered), so
    // the SQL is deterministic regardless of dictionary ordering.

    static func insert<M: Table>(
        _ validated: ValidatedChanges, into type: M.Type,
        onConflict: OnConflict<M>? = nil
    ) throws -> RenderedStatement {
        let schema = M.schema
        try checkKnown(validated.changedFields.keys, in: schema)
        let conflict = try onConflict.map { " \(try conflictClause($0))" } ?? ""
        let columns = schema.columns.filter { validated.changedFields[$0.name] != nil }
        guard !columns.isEmpty else {
            // Nothing changed: every column falls to its database default.
            return RenderedStatement(
                sql:
                    "INSERT INTO \(schema.quotedName) DEFAULT VALUES\(conflict) RETURNING \(schema.selectList)",
                binds: [])
        }
        var writer = BindWriter()
        let placeholders =
            try columns
            .map {
                writer.placeholder(
                    try changesetBind(
                        type, column: $0.name, value: validated.changedFields[$0.name]!, in: schema)
                )
            }
            .joined(separator: ", ")
        let sql = """
            INSERT INTO \(schema.quotedName) (\(columnList(columns))) \
            VALUES (\(placeholders))\(conflict) RETURNING \(schema.selectList)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func update<M: Table>(
        _ validated: ValidatedChanges, into type: M.Type
    ) throws -> RenderedStatement {
        let schema = M.schema
        guard let identity = validated.identity, !identity.isEmpty else {
            throw HangarError.updateWithoutIdentity(table: schema.name)
        }
        try checkKnown(validated.changedFields.keys, in: schema)
        try checkKnown(identity.keys, in: schema)
        let sets = schema.columns.filter { validated.changedFields[$0.name] != nil }
        guard !sets.isEmpty else {
            // The Repo short-circuits empty changesets; reaching here means
            // a hand-built ValidatedChanges with nothing to do.
            throw HangarError.noUpdatableColumns(table: schema.name)
        }
        var writer = BindWriter()
        let assignments =
            try sets
            .map {
                "\($0.quotedName) = \(writer.placeholder(try changesetBind(type, column: $0.name, value: validated.changedFields[$0.name]!, in: schema)))"
            }
            .joined(separator: ", ")
        let conditions = try schema.columns
            .filter { identity[$0.name] != nil }
            .map {
                "\($0.quotedName) = \(writer.placeholder(try changesetBind(type, column: $0.name, value: identity[$0.name]!, in: schema)))"
            }
            .joined(separator: " AND ")
        let sql = """
            UPDATE \(schema.quotedName) SET \(assignments) \
            WHERE \(conditions) \
            RETURNING \(schema.selectList)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    private static func changesetBind<M: Table>(
        _ type: M.Type, column: String, value: any Sendable, in schema: TableSchema
    ) throws -> SQLBind {
        guard let bind = M._changesetBind(column: column, value: value) else {
            throw HangarError.changesetValueMismatch(table: schema.name, column: column)
        }
        return bind
    }

    private static func checkKnown(
        _ names: some Sequence<String>, in schema: TableSchema
    ) throws {
        let known = Set(schema.columns.map(\.name))
        if let stray = names.first(where: { !known.contains($0) }) {
            throw HangarError.unknownColumn(table: schema.name, column: stray)
        }
    }

    /// `UPDATE ... SET <deletedAt> = $n WHERE <pk> AND <deletedAt> IS NULL`
    /// — a soft delete, stamping rather than removing.
    ///
    /// The `IS NULL` guard makes it honest about repeats: deleting an
    /// already-deleted row affects nothing, so the caller learns it was
    /// already gone rather than silently moving the timestamp.
    static func softDelete<M: Table>(_ model: M, at instant: Date) throws -> RenderedStatement {
        let schema = M.schema
        guard let column = schema.deletedAt else {
            throw HangarError.notSoftDeletable(table: schema.name)
        }
        var writer = BindWriter()
        let stamp = writer.placeholder(SQLBind(instant))
        let sql = """
            UPDATE \(schema.quotedName) SET \(column.quotedName) = \(stamp) \
            WHERE \(try primaryKeyClause(model, schema: schema, writer: &writer)) \
            AND \(column.quotedName) IS NULL \
            RETURNING \(schema.primaryKey[0].quotedName)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `UPDATE ... SET <deletedAt> = NULL` — undoing a soft delete.
    static func restore<M: Table>(_ model: M) throws -> RenderedStatement {
        let schema = M.schema
        guard let column = schema.deletedAt else {
            throw HangarError.notSoftDeletable(table: schema.name)
        }
        var writer = BindWriter()
        let sql = """
            UPDATE \(schema.quotedName) SET \(column.quotedName) = NULL \
            WHERE \(try primaryKeyClause(model, schema: schema, writer: &writer)) \
            AND \(column.quotedName) IS NOT NULL \
            RETURNING \(schema.primaryKey[0].quotedName)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    static func delete<M: Table>(_ model: M) throws -> RenderedStatement {
        let schema = M.schema
        var writer = BindWriter()
        // RETURNING the key so the Repo can distinguish "deleted" from
        // "no such row" without a command tag.
        let sql = """
            DELETE FROM \(schema.quotedName) \
            WHERE \(try primaryKeyClause(model, schema: schema, writer: &writer)) \
            RETURNING \(schema.primaryKey[0].quotedName)
            """
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `DELETE FROM ... WHERE <predicate> RETURNING <pk>` — every row the
    /// query's predicate matches.
    ///
    /// Only the predicate and any attached CTEs participate. A query
    /// carrying a clause DELETE cannot honor — LIMIT, OFFSET, ORDER BY,
    /// GROUP BY, HAVING, DISTINCT — throws rather than silently dropping
    /// it: a delete that ignores the LIMIT you wrote deletes rows you did
    /// not ask it to. So does one that `reading(from:)` a CTE, which would
    /// otherwise delete from the entity's real table instead.
    static func delete<M: Table, R>(_ query: Query<M, R>) throws -> RenderedStatement {
        try checkBulkWritable(query, operation: "delete")
        var writer = BindWriter()
        var sql = withClause(query.ctes, writer: &writer)
        sql += "DELETE FROM \(M.schema.quotedName)"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        sql += " RETURNING \(M.schema.primaryKey[0].quotedName)"
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// `UPDATE ... SET ... WHERE <predicate> RETURNING <pk>` — the same
    /// values written to every row the predicate matches.
    ///
    /// The same clause rules as bulk delete: only the predicate
    /// participates, and a query carrying anything UPDATE cannot honor
    /// throws rather than silently dropping it.
    static func update<M: Table, R>(
        _ query: Query<M, R>, set assignments: [ColumnAssignment]
    ) throws -> RenderedStatement {
        try checkBulkWritable(query, operation: "update")
        guard !assignments.isEmpty else {
            throw HangarError.noUpdatableColumns(table: M.schema.name)
        }
        var writer = BindWriter()
        // WITH first, so its binds are numbered in text order.
        let prefix = withClause(query.ctes, writer: &writer)
        let sets =
            assignments
            .map { "\(quote($0.name)) = \(render($0.expression, writer: &writer))" }
            .joined(separator: ", ")
        var sql = "\(prefix)UPDATE \(M.schema.quotedName) SET \(sets)"
        appendWhere(query.effectivePredicate, to: &sql, writer: &writer)
        sql += " RETURNING \(M.schema.primaryKey[0].quotedName)"
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    /// Rejects query clauses a bulk write cannot express. Postgres has no
    /// `DELETE ... LIMIT` or `UPDATE ... ORDER BY`; honoring the WHERE while
    /// ignoring the rest would be a silent wrong answer of exactly the kind
    /// this renderer refuses to produce.
    static func checkBulkWritable<M, R>(_ query: Query<M, R>, operation: String) throws {
        let unsupported: String?
        if query.rowLimit != nil {
            unsupported = "LIMIT"
        } else if query.rowOffset != nil {
            unsupported = "OFFSET"
        } else if !query.orderings.isEmpty {
            unsupported = "ORDER BY"
        } else if !query.grouping.isEmpty {
            unsupported = "GROUP BY"
        } else if query.having != nil {
            unsupported = "HAVING"
        } else if query.isDistinct {
            unsupported = "DISTINCT"
        } else if !query.distinctOn.isEmpty {
            unsupported = "DISTINCT ON"
        } else if let lock = query.rowLock {
            // DELETE and UPDATE already take their own row locks.
            unsupported = lock.rawValue
        } else if query.fromDerived != nil {
            // A set operation is a *source*, and DELETE/UPDATE target a table.
            // Rendered anyway, the derived source is simply dropped and the
            // statement becomes `DELETE FROM "posts"` with whatever predicate
            // the outer query happens to carry — which, for a combination, is
            // none. That is every row in the table, from a call that reads as
            // "delete the union of these two".
            unsupported = "set operation"
        } else if query.fromCTE != nil {
            // A CTE can *feed* a bulk write, but it cannot be its target:
            // `DELETE FROM "cte"` deletes nothing real. Attaching the CTE
            // with `with` and referencing it from the predicate is the
            // shape that works.
            unsupported = "reading(from:)"
        } else {
            unsupported = nil
        }
        if let unsupported {
            throw HangarError.bulkWriteClause(
                table: M.schema.name, operation: operation, clause: unsupported)
        }
    }

    /// A standalone statement from a fragment — the transaction escape
    /// hatch's rendering. Unlike a fragment *predicate* this is not
    /// parenthesized: `(SET LOCAL ...)` is not a statement.
    static func statement(_ fragment: SQLFragment) -> RenderedStatement {
        var writer = BindWriter()
        let sql = renderParts(fragment.parts, writer: &writer)
        return RenderedStatement(sql: sql, binds: writer.binds)
    }

    // MARK: Expression rendering

    /// `WITH a AS (...), b AS (...) ` — empty when there are no CTEs.
    ///
    /// Rendered before anything else in the statement so its binds are
    /// numbered in text order. `RECURSIVE` is a property of the whole
    /// `WITH` list in Postgres, not of one member, so one recursive CTE
    /// puts the keyword in front of all of them — which is legal for the
    /// non-recursive members and changes nothing about them.
    static func withClause(
        _ ctes: [CommonTableExpression], writer: inout BindWriter
    ) -> String {
        guard !ctes.isEmpty else { return "" }
        let recursive = ctes.contains(where: \.isRecursive) ? "RECURSIVE " : ""
        let bodies = ctes.map { cte -> String in
            let text: String
            switch cte.body {
            case .fragment(let parts):
                text = renderParts(parts, writer: &writer)
            case .query(let render):
                text = render(&writer)
            }
            let suffix = cte.trailingClause.map { " \($0)" } ?? ""
            return "\(quote(cte.name)) AS (\(text))\(suffix)"
        }
        return "WITH \(recursive)\(bodies.joined(separator: ", ")) "
    }

    /// What a select reads from: the entity's table, or a CTE aliased back
    /// to the entity's table name so every column qualification downstream
    /// still resolves.
    static func source<M: Table>(_ type: M.Type, cte: String?) -> String {
        guard let cte else { return M.schema.quotedName }
        return "\(quote(cte)) AS \(M.schema.quotedName)"
    }

    /// `FROM (…) AS "posts"` for a query reading a derived table.
    ///
    /// Aliased as the entity's own table so every column reference downstream
    /// — predicates, ordering, preloads — qualifies exactly as it would
    /// against the table itself. Postgres requires the alias regardless.
    static func source<M: Table>(
        _ type: M.Type, query: Query<M, some Sendable>, writer: inout BindWriter
    ) -> String {
        guard let derived = query.fromDerived else { return source(M.self, cte: query.fromCTE) }
        return "(\(derived(&writer))) AS \(M.schema.quotedName)"
    }

    /// Fragment parts as SQL, appending binds — the unparenthesized form,
    /// for a CTE body or any other whole-statement position. The predicate
    /// path in ``render(_:writer:)`` parenthesizes instead, because a
    /// fragment predicate has to compose under `AND`/`OR`.
    static func renderParts(_ parts: [SQLFragment.Part], writer: inout BindWriter) -> String {
        var text = ""
        for part in parts {
            switch part {
            case .sql(let sql):
                text += sql
            case .bind(let bind):
                text += writer.placeholder(bind)
            case .column(let table, let name):
                if writer.qualified, !table.isEmpty {
                    text += "\(quote(table)).\(quote(name))"
                } else {
                    text += quote(name)
                }
            }
        }
        return text
    }

    static func appendWhere(_ predicate: Predicate?, to sql: inout String, writer: inout BindWriter)
    {
        guard let predicate else { return }
        sql += " WHERE \(render(predicate.expression, writer: &writer))"
    }

    /// Every compound is fully parenthesized — slightly noisy SQL, zero
    /// precedence ambiguity.
    static func render(_ expression: SQLExpression, writer: inout BindWriter) -> String {
        switch expression {
        case .column(let table, let name):
            if writer.qualified, !table.isEmpty {
                return "\(quote(table)).\(quote(name))"
            }
            return quote(name)
        case .bind(let bind):
            return writer.placeholder(bind)
        case .infix(let op, let lhs, let rhs):
            return "(\(render(lhs, writer: &writer)) \(op) \(render(rhs, writer: &writer)))"
        case .anyOf(let lhs, let rhs):
            return "(\(render(lhs, writer: &writer)) = ANY(\(render(rhs, writer: &writer))))"
        case .function(let name, let arguments):
            let rendered = arguments.map { render($0, writer: &writer) }.joined(separator: ", ")
            return "\(name)(\(rendered))"
        case .window(let operand, let specification):
            // Binds inside the operand are written before the window's own,
            // which is the order the text carries them — PARTITION BY and
            // ORDER BY take columns, not values, so in practice the window
            // contributes none. Rendering through the same writer keeps that
            // true if it ever stops being.
            let function = render(operand, writer: &writer)
            var clauses: [String] = []
            if !specification.partitions.isEmpty {
                let columns = specification.partitions
                    .map { render($0, writer: &writer) }
                    .joined(separator: ", ")
                clauses.append("PARTITION BY \(columns)")
            }
            if !specification.orderings.isEmpty {
                let terms = specification.orderings
                    .map { term -> String in
                        let column =
                            writer.qualified && !term.table.isEmpty
                            ? "\(quote(term.table)).\(quote(term.column))" : quote(term.column)
                        return "\(column) \(term.clause)"
                    }
                    .joined(separator: ", ")
                clauses.append("ORDER BY \(terms)")
            }
            if let frame = specification.frame { clauses.append(frame) }
            return "\(function) OVER (\(clauses.joined(separator: " ")))"
        case .cast(let operand, let type):
            return "(\(render(operand, writer: &writer)))::\(type)"
        case .inSubquery(let lhs, let subquery):
            return "(\(render(lhs, writer: &writer)) IN (\(subquery.render(&writer))))"
        case .scalarSubquery(let subquery):
            return "(\(subquery.render(&writer)))"
        case .existsSubquery(let subquery):
            return "EXISTS (\(subquery.render(&writer)))"
        case .fragment(let parts):
            // Parenthesized so a fragment predicate composes under AND/OR
            // without precedence surprises. `renderParts` is the same
            // rendering unparenthesized, for whole-statement positions.
            return "(" + renderParts(parts, writer: &writer) + ")"
        case .not(let operand):
            return "NOT (\(render(operand, writer: &writer)))"
        case .isNull(let operand):
            return "(\(render(operand, writer: &writer)) IS NULL)"
        case .isNotNull(let operand):
            return "(\(render(operand, writer: &writer)) IS NOT NULL)"
        }
    }

    // MARK: Helpers

    private static func primaryKeyClause<M: Table>(
        _ model: M, schema: TableSchema, writer: inout BindWriter
    ) throws -> String {
        try schema.primaryKey
            .map {
                "\($0.quotedName) = \(writer.placeholder(try bind(model, $0.name, in: schema)))"
            }
            .joined(separator: " AND ")
    }

    private static func bind<M: Table>(_ model: M, _ column: String, in schema: TableSchema) throws
        -> SQLBind
    {
        guard let bind = model._bind(for: column) else {
            throw HangarError.unknownColumn(table: schema.name, column: column)
        }
        return bind
    }

    /// For dynamic subsets only (changeset writes); the whole-table lists
    /// are precomputed on `TableSchema`.
    private static func columnList(_ columns: [ColumnDefinition]) -> String {
        columns.map(\.quotedName).joined(separator: ", ")
    }

    /// Double-quotes an identifier, doubling any embedded quote. The
    /// common case (no embedded quote) avoids Foundation's
    /// `replacingOccurrences`, which is slow enough to dominate rendering
    /// when called per column per query. Identifiers are almost always
    /// pre-quoted at schema-construction time anyway; this is the fallback.
    static func quote(_ identifier: String) -> String {
        guard identifier.utf8.contains(UInt8(ascii: "\"")) else {
            return "\"\(identifier)\""
        }
        return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
