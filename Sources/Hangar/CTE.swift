// Common table expressions: naming a subquery so a later clause — or the
// subquery itself — can refer to it.
//
// The typed half of Hangar stops at the CTE boundary on purpose. A CTE's
// body is a query shape the entity's own columns cannot describe: a
// recursive step references the CTE being defined, an aggregate rollup
// produces columns no `Table` declares. So the body is an `SQLFragment` —
// real binds, no string concatenation — and the *result* is typed, because
// a CTE that produces an entity's columns can be read back as that entity.
//
// The trick that makes reading typed with no rendering changes: a query
// reading from a CTE renders `FROM "cte_name" AS "entity_table"`. Every
// column reference downstream already qualifies with the entity's table
// name, so it resolves against the alias unchanged.

/// A named subquery attached to a query, rendered into its `WITH` clause.
///
/// Built by ``Query/with(_:as:)-(String,SQLFragment)``,
/// ``Query/with(_:as:)-(String,Query<M2,R2>)`` and
/// ``Query/withRecursive(_:anchor:recursive:)``. You do not construct one
/// directly.
public struct CommonTableExpression: Sendable {
    let name: String
    let isRecursive: Bool
    let body: Body
    /// Rendered after the body's closing paren — `CYCLE … SET … USING …`.
    /// Postgres puts it there, outside the parentheses, because it is a
    /// property of the recursion rather than of the query inside it.
    var trailingClause: String? = nil

    enum Body: Sendable {
        /// A raw body with binds — the general case.
        case fragment([SQLFragment.Part])
        /// A typed body rendered from a `Query`, deferred so its binds land
        /// in the outer statement's writer in text order.
        case query(@Sendable (inout BindWriter) -> String)
    }
}

extension Query {

    // MARK: - Common table expressions

    /// Names a subquery, so this query's predicate, join or selection can
    /// refer to it.
    ///
    /// The body is raw SQL with real binds — interpolated values become
    /// placeholders, exactly as in a ``SQLFragment`` predicate:
    ///
    /// ```swift
    /// Order.all
    ///     .with("recent", as: """
    ///         SELECT "customer_id", count(*) AS "n" FROM "orders"
    ///         WHERE "placed_at" > \(cutoff) GROUP BY "customer_id"
    ///         """)
    ///     .where { _ in
    ///         SQLFragment(#""orders"."customer_id" IN (SELECT "customer_id" FROM "recent" WHERE "n" > 5)"#)
    ///     }
    /// ```
    ///
    /// CTEs render in the order they were added, which is the order
    /// Postgres requires when one refers to another.
    ///
    /// - Note: `WITH` attaches to reads. ``Repo/delete(_:)-(Query<M,R>)``
    ///   and ``Repo/update(_:set:)`` render it too, but a query that also
    ///   ``reading(from:)-(String)`` a CTE is refused there rather than silently
    ///   deleting from the wrong table.
    public func with(_ name: String, as body: SQLFragment) -> Query {
        var next = self
        next.ctes.append(
            CommonTableExpression(name: name, isRecursive: false, body: .fragment(body.parts)))
        return next
    }

    /// Names a subquery written as a `Query` — the typed body, for when the
    /// CTE is an ordinary select over an entity.
    ///
    /// ```swift
    /// Employee.all
    ///     .with("engineers", as: Employee.where { $0.department == "eng" })
    ///     .reading(from: "engineers")
    ///     .orderBy { $0.hiredAt }
    /// ```
    ///
    /// The inner query's binds land in the outer statement in text order,
    /// so nothing renumbers.
    public func with<M2: Table, R2>(_ name: String, as body: Query<M2, R2>) -> Query {
        var next = self
        next.ctes.append(
            CommonTableExpression(
                name: name, isRecursive: false,
                body: .query { writer in SQLRenderer.selectText(body, writer: &writer) }))
        return next
    }

    /// Names a recursive subquery: a typed anchor, `UNION ALL`, and a raw
    /// recursive step.
    ///
    /// The step is the half that must be raw — it refers to the CTE being
    /// defined, which no entity's columns can describe. The anchor is the
    /// half people get wrong less often *and* the half that fixes the CTE's
    /// column names, so it stays typed.
    ///
    /// ```swift
    /// // Every employee under a manager, at any depth.
    /// let subtree = Employee.all
    ///     .withRecursive(
    ///         "subtree",
    ///         anchor: Employee.where { $0.id == rootID },
    ///         recursive: """
    ///             SELECT "employees".* FROM "employees"
    ///             JOIN "subtree" ON "employees"."manager_id" = "subtree"."id"
    ///             """)
    ///     .reading(from: "subtree")
    ///     .orderBy { $0.name }
    ///
    /// let team = try await repo.all(subtree)      // [Employee]
    /// ```
    ///
    /// The anchor's select list is the entity's full column list, so the
    /// CTE exposes exactly the columns ``reading(from:)-(String)`` expects. The
    /// recursive step must produce the same columns in the same order —
    /// Postgres rejects the statement if it does not.
    ///
    /// `RECURSIVE` applies to the whole `WITH` list in Postgres, so adding
    /// one recursive CTE makes the keyword appear once, for all of them.
    /// That is legal for non-recursive members and changes nothing about
    /// them.
    ///
    /// - Warning: A recursive step with no terminating condition runs
    ///   forever. Cycles in the data need a depth column or a visited-path
    ///   array in the step, the same as in hand-written SQL.
    public func withRecursive<M2: Table, R2>(
        _ name: String, anchor: Query<M2, R2>, recursive step: SQLFragment
    ) -> Query {
        var next = self
        let parts = step.parts
        next.ctes.append(
            CommonTableExpression(
                name: name, isRecursive: true,
                body: .query { writer in
                    let head = SQLRenderer.selectText(anchor, writer: &writer)
                    let tail = SQLRenderer.renderParts(parts, writer: &writer)
                    return "\(head) UNION ALL \(tail)"
                }))
        return next
    }

    /// Names a recursive subquery whose anchor is also raw.
    ///
    /// Reach for this when the anchor is not an ordinary entity select —
    /// `SELECT 1, ARRAY[id]` seeding a path column, say. The body must
    /// contain the whole `anchor UNION ALL step`.
    public func withRecursive(_ name: String, as body: SQLFragment) -> Query {
        var next = self
        next.ctes.append(
            CommonTableExpression(name: name, isRecursive: true, body: .fragment(body.parts)))
        return next
    }

    /// Reads this query's rows from a CTE instead of the entity's table.
    ///
    /// Renders `FROM "<cte>" AS "<entity table>"`, so every column
    /// reference, ordering, predicate and preload downstream works
    /// unchanged — they qualify with the entity's table name, and the alias
    /// supplies it.
    ///
    /// The CTE must expose the entity's columns. A body built from a `Query`
    /// over the same entity does so by construction; a raw body is on you.
    ///
    /// ```swift
    /// Employee.all
    ///     .with("engineers", as: Employee.where { $0.department == "eng" })
    ///     .reading(from: "engineers")
    /// ```
    ///
    /// Calling it twice keeps the last name.
    public func reading(from cte: String) -> Query {
        var next = self
        next.fromCTE = cte
        return next
    }
}
