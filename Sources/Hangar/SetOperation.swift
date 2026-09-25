// UNION, INTERSECT and EXCEPT between two queries over the same entity.
//
// Each one reads the combination as a derived table, so the result is an
// ordinary `Query` again: everything downstream —
// `where`, `order`, `limit`, preloads, `count`, `delete` — works on the
// combined set without knowing how it was built, and without this file
// teaching the renderer a second shape of statement.
//
// **Whole rows only.** These are available where `Result == Model`, which is
// how the two branches are guaranteed to have the same columns in the same
// order. Postgres requires exactly that:
//
//     ERROR:  each UNION query must have the same number of columns
//
// and with both sides selecting one entity's columns it cannot be otherwise.
// Projections would have to line up their select lists by hand, and the outer
// query would have to read the aliases back rather than the entity's columns;
// that is a larger design and not this one.

/// Which set operation combines two queries.
public enum SetOperator: String, Sendable {
    /// Rows in either, with duplicates removed.
    case union = "UNION"
    /// Rows in either, keeping duplicates — cheaper, because nothing has to
    /// be sorted or hashed to find them.
    case unionAll = "UNION ALL"
    /// Rows in both.
    case intersect = "INTERSECT"
    /// Rows in the left that are not in the right. Order matters here, unlike
    /// the other three.
    case except = "EXCEPT"
}

extension Query where Result == Model {

    /// Rows matching either query, with duplicates removed.
    ///
    /// ```swift
    /// let urgent = Post.where { $0.viewCount > 10_000 }
    /// let recent = Post.where { $0.createdAt > cutoff }
    /// try await repo.all(urgent.union(recent).order { $0.createdAt.desc() }.limit(20))
    /// ```
    ///
    /// The ordering and limit above apply to the combined set, not to either
    /// branch — they are clauses of the query that reads it.
    public func union(_ other: Query<Model, Model>) -> Query<Model, Model> {
        combined(.union, with: other)
    }

    /// Rows matching either query, keeping duplicates.
    ///
    /// Prefer this when the branches cannot overlap, or when duplicates are
    /// wanted: `UNION` has to deduplicate, and that is a sort or a hash over
    /// everything both branches returned.
    public func unionAll(_ other: Query<Model, Model>) -> Query<Model, Model> {
        combined(.unionAll, with: other)
    }

    /// Rows matching both queries.
    public func intersect(_ other: Query<Model, Model>) -> Query<Model, Model> {
        combined(.intersect, with: other)
    }

    /// Rows matching this query and not the other.
    ///
    /// The only one of the four where the order of the operands changes the
    /// answer.
    public func except(_ other: Query<Model, Model>) -> Query<Model, Model> {
        combined(.except, with: other)
    }

    /// Reads the combination as a derived table.
    ///
    /// Both branches are parenthesised, which is what lets each keep its own
    /// `ORDER BY` or `LIMIT` — "the twenty most viewed, plus the five newest"
    /// is two bounded branches, and Postgres rejects a bare `ORDER BY` in the
    /// left-hand side of a set operation.
    ///
    /// **Why a derived table and not a named CTE.** The first version named
    /// the combination `hangar_set_N`, numbered from how many CTEs the two
    /// sides already had. That collides: `a.union(b).union(c.union(d))` builds
    /// two independent subtrees that each numbered their own CTE `1`, and
    /// merging them produced a `WITH` list with the name twice —
    ///
    ///     ERROR:  WITH query name "hangar_set_1" specified more than once
    ///
    /// A derived table needs no name, so there is nothing to collide. The
    /// branches' own CTEs still merge, because a `WITH` list is flat and a
    /// branch may legitimately have one.
    func combined(_ op: SetOperator, with other: Query<Model, Model>) -> Query<Model, Model> {
        let left = self
        let right = other

        // Postgres refuses `FOR UPDATE` on a set operation or its branches:
        // "FOR UPDATE is not allowed with UNION/INTERSECT/EXCEPT". This was a
        // precondition, which took the whole process down on the request
        // that built the query. It is recorded instead, and running the
        // query throws ``HangarError/rowLockOnSetOperation`` before anything
        // reaches the server.
        var next = Query<Model, Model>()
        next.lockedSetOperationBranch =
            rowLock != nil || other.rowLock != nil
            || lockedSetOperationBranch || other.lockedSetOperationBranch
        // The branches have already chosen their rows, including which
        // soft-deleted ones. Applying the entity's default scope again on the
        // outside is double-filtering, and it is wrong in every direction:
        // `onlyDeleted().union(onlyDeleted())` selected `deleted_at IS NOT
        // NULL` twice and then asked for `IS NULL`, which is empty; and
        // `withDeleted().union(…)` quietly excluded what it had just asked
        // for. `.included` here means "add no condition" — the derived source
        // already contains exactly what the branches selected.
        //
        // Scoping the *combination* still works: `.onlyDeleted()` on the
        // result applies to the combined rows, which is what it reads as.
        next.deletedRows = .included
        next.ctes = ctes + other.ctes
        next.fromDerived = { writer in
            // Rendered with the outer writer, in text order, so the two
            // branches' binds keep their numbering.
            var leftQuery = left
            var rightQuery = right
            leftQuery.ctes = []
            rightQuery.ctes = []
            let a = SQLRenderer.selectText(leftQuery, writer: &writer)
            let b = SQLRenderer.selectText(rightQuery, writer: &writer)
            return "(\(a)) \(op.rawValue) (\(b))"
        }
        return next
    }
}
