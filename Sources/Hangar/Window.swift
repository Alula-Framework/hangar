// Window functions: a value computed from the rows *around* this one.
//
// The seam is `SelectExpression`, which already carries every derived
// SELECT-list item this package produces. Attaching `.over(_:)` there means
// every aggregate that existed before this file becomes a window function
// without gaining an overload: `sum()` answers "of the group", and
// `sum().over { … }` answers "of the rows I am windowed with", from the same
// call site.
//
// **Not here yet:** frame clauses (`ROWS BETWEEN …`). A window without a frame
// is the whole partition, which is what running totals and rankings need; a
// moving average needs a frame and cannot be expressed today. Additive when it
// lands — it is another clause inside the parentheses, not a new shape.
//
// **A window function belongs in the SELECT list.** Postgres rejects one in
// `WHERE`, `GROUP BY` or `HAVING`, and so will your build — at the server
// rather than the compiler, because `SelectExpression` carries the comparison
// operators that `having` is built from and separating the two types would
// cost more than the mistake does.

/// Which rows a window function reads, and in what order.
///
/// Built by chaining, like every other query value here. The empty window —
/// `.over()` with no builder — is `OVER ()`: every row the query returned,
/// unordered, which is how `count().over()` puts the total beside each row.
public struct Window: Sendable {
    var specification = WindowSpecification()

    public init() {}

    /// Restart the function for each distinct value of this column.
    ///
    /// `PARTITION BY author_id` makes `row_number()` count 1, 2, 3 within each
    /// author rather than across the whole result.
    public func partition<Value>(by column: Column<Value>) -> Window {
        var copy = self
        copy.specification.partitions.append(column.expression)
        return copy
    }

    /// Order the rows *within* the partition.
    ///
    /// This is what `rank()` ranks by and what a running `sum()` accumulates
    /// along. It is independent of the query's own `ORDER BY`, which decides
    /// the order rows come back in — the same term usually belongs in both,
    /// and forgetting that is why a ranking can look shuffled.
    public func order(_ term: OrderTerm) -> Window {
        var copy = self
        copy.specification.orderings.append(term)
        return copy
    }
}

extension SelectExpression {
    /// Read this expression over a window of rows instead of the whole group.
    ///
    /// ```swift
    /// Post.select(into: Ranked.self) { p in
    ///     (p.title, p.viewCount,
    ///      p.viewCount.sum().over { $0.partition(by: p.authorID) })
    /// }
    /// ```
    ///
    /// With no builder it is `OVER ()`: the whole result set.
    public func over(_ build: (Window) -> Window = { $0 }) -> WindowExpression<Value> {
        let specification = build(Window()).specification
        // The window binds tighter than a cast: `sum(x)` renders as
        // `(sum(x))::bigint` so integer sums decode, and the window belongs
        // *inside* that — `(sum(x) OVER (…))::bigint`. Wrapping the cast
        // instead produces `(sum(x))::bigint OVER (…)`, which Postgres rejects
        // as a syntax error at OVER. Caught by running it, not by reading it:
        // the first version of this shipped with a render test asserting the
        // broken spelling was correct.
        if case .cast(let inner, let type) = expression {
            return WindowExpression<Value>(expression: .cast(.window(inner, specification), type))
        }
        return WindowExpression<Value>(expression: .window(expression, specification))
    }
}

/// A function that is meaningless without a window, and so cannot be written
/// without one.
///
/// `row_number()` is not an aggregate — it has no answer for "the whole group"
/// and Postgres rejects it outside `OVER`. Rather than return a
/// ``SelectExpression`` that renders to invalid SQL until someone remembers to
/// call `.over`, these return a value whose *only* method is `.over`. The
/// mistake is unspellable rather than diagnosed.
public struct WindowOnlyFunction<Value>: Sendable {
    let function: SQLExpression
    /// Applied *after* the window, for the reason ``SelectExpression/over(_:)``
    /// gives: `(row_number() OVER (…))::int`, never `(row_number())::int OVER`.
    let castTo: String?

    /// Fix this function to a window. Required — it is the only thing you can
    /// do with this value.
    public func over(_ build: (Window) -> Window = { $0 }) -> WindowExpression<Value> {
        let windowed = SQLExpression.window(function, build(Window()).specification)
        guard let castTo else { return WindowExpression<Value>(expression: windowed) }
        return WindowExpression<Value>(expression: .cast(windowed, castTo))
    }
}

/// The ranking functions, which exist only inside a window.
public enum WindowFunctions {
    /// `row_number()` — 1, 2, 3 … within the partition, never tied.
    public static func rowNumber() -> WindowOnlyFunction<Int> {
        WindowOnlyFunction(function: .function("row_number", []), castTo: "int")
    }

    /// `rank()` — ties share a number and the next value skips (1, 1, 3).
    public static func rank() -> WindowOnlyFunction<Int> {
        WindowOnlyFunction(function: .function("rank", []), castTo: "int")
    }

    /// `dense_rank()` — ties share a number and the next value does not skip
    /// (1, 1, 2).
    public static func denseRank() -> WindowOnlyFunction<Int> {
        WindowOnlyFunction(function: .function("dense_rank", []), castTo: "int")
    }
}

extension Column {
    /// `lag(column, offset)` — this column's value from a row earlier in the
    /// window, or NULL at the start of the partition.
    ///
    /// Optional for that reason: the first row of every partition has nothing
    /// behind it, and a type that pretended otherwise would be lying on every
    /// partition boundary.
    ///
    /// The offset is bound and then cast: PostgresNIO sends a Swift `Int` as
    /// `bigint`, and `lag(integer, bigint)` is not a function Postgres has —
    /// it wants `integer`. Casting the parameter keeps the value bound, which
    /// is the rule here; inlining it as text would have been the easy fix and
    /// the wrong one.
    public func lag(_ offset: Int = 1) -> WindowOnlyFunction<Value?> {
        WindowOnlyFunction(
            function: .function("lag", [expression, .cast(.bind(SQLBind(offset)), "int")]),
            castTo: nil)
    }

    /// `lead(column, offset)` — this column's value from a row later in the
    /// window, or NULL at the end of the partition.
    public func lead(_ offset: Int = 1) -> WindowOnlyFunction<Value?> {
        WindowOnlyFunction(
            function: .function("lead", [expression, .cast(.bind(SQLBind(offset)), "int")]),
            castTo: nil)
    }
}

/// The result of `.over` — selectable, and deliberately not comparable.
///
/// Postgres rejects a window function in `WHERE` and in `HAVING`:
///
///     ERROR:  window functions are not allowed in WHERE
///     ERROR:  window functions are not allowed in HAVING
///
/// Both used to compile here and fail at the server, on the first request that
/// ran the query. They are compile errors now, because this type carries no
/// comparison operators — and the unavailable overloads below exist so the
/// compiler says *why* instead of "binary operator cannot be applied".
public struct WindowExpression<Value>: Sendable, Selectable {
    let expression: SQLExpression

    /// The expression as a SELECT-list item — not user API.
    public var _selectFragment: SelectFragment { SelectFragment(expression: expression) }
}

// MARK: - Comparisons that would be invalid SQL
//
// Declared only to be unavailable. Overload resolution picks them for a
// windowed operand and reports the message, which is the whole point: a
// missing operator gives a reader nothing to act on, and this mistake has a
// specific fix worth naming.

@available(
    *, unavailable,
    message: """
        Window functions are not allowed in WHERE or HAVING — Postgres rejects this.
        A window is computed after those clauses have already chosen the rows, so it
        cannot decide which rows they choose. Select it here, put this query in a CTE
        with `.with(...)`, and compare the column in the outer query.
        """
)
public func > <V>(lhs: WindowExpression<V>, rhs: V) -> Predicate { fatalError() }

@available(
    *, unavailable,
    message: """
        Window functions are not allowed in WHERE or HAVING — Postgres rejects this.
        A window is computed after those clauses have already chosen the rows, so it
        cannot decide which rows they choose. Select it here, put this query in a CTE
        with `.with(...)`, and compare the column in the outer query.
        """
)
public func >= <V>(lhs: WindowExpression<V>, rhs: V) -> Predicate { fatalError() }

@available(
    *, unavailable,
    message: """
        Window functions are not allowed in WHERE or HAVING — Postgres rejects this.
        A window is computed after those clauses have already chosen the rows, so it
        cannot decide which rows they choose. Select it here, put this query in a CTE
        with `.with(...)`, and compare the column in the outer query.
        """
)
public func < <V>(lhs: WindowExpression<V>, rhs: V) -> Predicate { fatalError() }

@available(
    *, unavailable,
    message: """
        Window functions are not allowed in WHERE or HAVING — Postgres rejects this.
        A window is computed after those clauses have already chosen the rows, so it
        cannot decide which rows they choose. Select it here, put this query in a CTE
        with `.with(...)`, and compare the column in the outer query.
        """
)
public func <= <V>(lhs: WindowExpression<V>, rhs: V) -> Predicate { fatalError() }

@available(
    *, unavailable,
    message: """
        Window functions are not allowed in WHERE or HAVING — Postgres rejects this.
        A window is computed after those clauses have already chosen the rows, so it
        cannot decide which rows they choose. Select it here, put this query in a CTE
        with `.with(...)`, and compare the column in the outer query.
        """
)
public func == <V>(lhs: WindowExpression<V>, rhs: V) -> Predicate { fatalError() }
