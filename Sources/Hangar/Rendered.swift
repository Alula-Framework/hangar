import PostgresNIO

// Seeing (and reusing) the SQL a query renders to. Useful for debugging a
// surprising result, for `EXPLAIN`, for logging, and for the escape hatch
// of running a Hangar-built statement through PostgresNIO directly.
//
// Values are never interpolated into these strings — `debugSQL` shows the
// `$1, $2, …` placeholders exactly as sent, which is also why it is safe to
// log.

extension Query {
    /// The SQL this query renders to, with `$n` placeholders where values
    /// will be bound. Never contains user values.
    public var debugSQL: String {
        SQLRenderer.select(self).sql
    }

    /// The rendered statement with its binds applied — what `Repo` sends.
    /// Throws for a malformed projection or an unencodable value, before
    /// anything reaches the wire.
    public func renderedQuery() throws -> PostgresQuery {
        if let invalid = selection?.invalid { throw invalid }
        return try SQLRenderer.select(self).postgresQuery()
    }

    /// The `DELETE ... WHERE ... RETURNING` a bulk `repo.delete(self)`
    /// renders to. Throws `HangarError.bulkWriteClause` for the same
    /// clauses `Repo.delete` itself refuses.
    public func debugDeleteSQL() throws -> String {
        try SQLRenderer.delete(self).sql
    }

    /// The `UPDATE ... SET ... WHERE ... RETURNING` a bulk
    /// `repo.update(self, set:)` renders to, given the same assignment
    /// builder that call takes.
    public func debugUpdateSQL<each A: Assignable>(
        set build: (Model.QueryColumns) -> (repeat each A)
    ) throws -> String {
        let built = build(Model.queryColumns)
        var assignments: [ColumnAssignment] = []
        for assignment in repeat each built {
            assignments.append(assignment._assignment)
        }
        return try SQLRenderer.update(self, set: assignments).sql
    }
}

extension JoinedQuery {
    /// The SQL with `$n` placeholders — for logging and tests.
    public var debugSQL: String {
        (try? SQLRenderer.select(self).sql) ?? "<invalid join: \(A.self) ⋈ \(B.self)>"
    }

    /// The rendered statement with its binds applied — what `Repo` sends.
    public func renderedQuery() throws -> PostgresQuery {
        if let invalid = selection?.invalid { throw invalid }
        return try SQLRenderer.select(self).postgresQuery()
    }
}

extension JoinedQuery3 {
    /// The SQL with `$n` placeholders — for logging and tests.
    public var debugSQL: String {
        (try? SQLRenderer.select(self).sql) ?? "<invalid join: \(A.self) ⋈ \(B.self) ⋈ \(C.self)>"
    }

    /// The rendered statement with its binds applied — what `Repo` sends.
    public func renderedQuery() throws -> PostgresQuery {
        if let invalid = selection?.invalid { throw invalid }
        return try SQLRenderer.select(self).postgresQuery()
    }
}

extension ComposedQuery {
    /// The SQL with `$n` placeholders — for logging and tests. Unlike
    /// `JoinedQuery`/`JoinedQuery3`'s `debugSQL`, this never has an
    /// ambiguous-alias case to catch — every alias `QueryBuilder` mints is
    /// fresh by construction — so there is nothing to fall back to.
    public var debugSQL: String {
        SQLRenderer.select(self).sql
    }

    /// The rendered statement with its binds applied — what `Repo` sends.
    public func renderedQuery() throws -> PostgresQuery {
        if let invalid = selection?.invalid { throw invalid }
        return try SQLRenderer.select(self).postgresQuery()
    }
}

extension Table {
    /// The `INSERT... RETURNING` this model renders to.
    public func debugInsertSQL() throws -> String {
        try SQLRenderer.insert(self).sql
    }

    /// The `UPDATE... WHERE key... RETURNING` this model renders to.
    public func debugUpdateSQL() throws -> String {
        try SQLRenderer.update(self).sql
    }
}

extension Array where Element: Table {
    /// The multi-row `INSERT ... VALUES (...), (...), ... RETURNING` for the
    /// whole batch. `repo.insert(self)` sends exactly this unless the batch
    /// exceeds the bind-parameter limit, when it sends it in chunks.
    public func debugInsertSQL() throws -> String {
        try SQLRenderer.insert(self).sql
    }
}

/// Identifier quoting, exposed for the test that pins the escaping rules.
/// Underscored and undocumented as API: `quote` is an internal detail of
/// rendering, but its escaping behavior is a correctness property worth a
/// test.
