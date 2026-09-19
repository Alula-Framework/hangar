// A query used as one column of another query's SELECT list.
//
// The machinery is the one `exists()` already uses: a deferred render that
// flips the writer into qualified mode, so the inner query's WHERE can name
// the outer query's columns and both sides come out unambiguous. The only
// difference is what the subquery selects — one expression instead of `1`.
//
// This is the shape that has no other spelling today. A per-row count can be
// had from a join plus a GROUP BY, but that changes the grouping of the outer
// query and forces every other column into an aggregate; and a preload answers
// it in a second round trip. Neither is "one more column on these rows".

extension Query where Result == Model {

    /// This query as a single projected value — `(SELECT … FROM … WHERE …)`.
    ///
    /// Correlated, exactly like ``exists()``: the predicate may reference the
    /// outer query's columns.
    ///
    /// ```swift
    /// Post.select(into: WithAuthorName.self) { post in
    ///     (title: post.title,
    ///      author: Author.where { $0.id == post.authorID }.scalar { $0.name })
    /// }
    /// ```
    ///
    /// Optional because a subquery matching no row is SQL NULL, and because a
    /// type that claimed otherwise would be wrong on the first orphan. A
    /// `LIMIT 1` is imposed: more than one row is a runtime error in Postgres
    /// ("more than one row returned by a subquery used as an expression"), and
    /// the limit is the difference between "the author's name" and a query
    /// that works until two rows match.
    public func scalar<V>(
        _ build: (Model.QueryColumns) -> some Selectable<V>
    ) -> SelectExpression<V?> {
        SelectExpression<V?>(
            expression: scalarExpression(
                rendering: build(Model.queryColumns)._selectFragment.expression,
                limitToOne: true))
    }

    /// How many rows this query matches, as a projected column.
    ///
    /// Non-optional, and no `LIMIT`: `count(*)` over no rows is 0, not NULL,
    /// and it is always exactly one row.
    ///
    /// ```swift
    /// Post.select(into: PostWithCount.self) { post in
    ///     (title: post.title,
    ///      comments: Comment.where { $0.postID == post.id }.scalarCount())
    /// }
    /// ```
    public func scalarCount() -> SelectExpression<Int> {
        SelectExpression<Int>(
            expression: scalarExpression(overrideList: "count(*)", limitToOne: false))
    }

    private func scalarExpression(
        rendering expression: SQLExpression? = nil,
        overrideList: String? = nil,
        limitToOne: Bool
    ) -> SQLExpression {
        // `let`, not `var`: the closure escapes, and a captured var is not
        // Sendable under strict concurrency.
        let inner: Query<Model, Model> = {
            guard limitToOne else { return self }
            var limited = self
            limited.rowLimit = 1
            return limited
        }()
        return .scalarSubquery(
            SubquerySQL { writer in
                let wasQualified = writer.qualified
                writer.qualified = true
                defer { writer.qualified = wasQualified }
                // The select list renders first because that is where it sits
                // in the text, and binds are numbered in text order.
                let list = overrideList ?? SQLRenderer.render(expression!, writer: &writer)
                return SQLRenderer.selectText(inner, writer: &writer, overrideList: list)
            })
    }
}
