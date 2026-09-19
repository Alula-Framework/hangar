// Window functions: a value computed from the rows *around* this one.
//
// The seam is `SelectExpression`, which already carries every derived
// SELECT-list item this package produces. Attaching `.over(_:)` there means
// every aggregate that existed before this file becomes a window function
// without gaining an overload: `sum()` answers "of the group", and
// `sum().over { … }` answers "of the rows I am windowed with", from the same
// call site.
//
// **A window function belongs in the SELECT list.** Postgres rejects one in
// `WHERE`, `GROUP BY` or `HAVING`, and so will your build — at the server
// rather than the compiler, because `SelectExpression` carries the comparison
// operators that `having` is built from and separating the two types would
// cost more than the mistake does.

/// Where a frame starts.
///
/// Split from ``FrameEnd`` because two of Postgres's three frame errors are
/// about which keyword may appear on which side:
///
///     ERROR:  frame start cannot be UNBOUNDED FOLLOWING
///     ERROR:  frame end cannot be UNBOUNDED PRECEDING
///
/// Neither is spellable here. The third — a start *after* the end, such as
/// `1 FOLLOWING` to `1 PRECEDING` — depends on the offsets rather than the
/// keywords, and Postgres reports it as "frame starting from following row
/// cannot have preceding rows".
public enum FrameStart: Sendable {
    /// Every row from the start of the partition.
    case unboundedPreceding
    /// `n` rows back from the current one.
    case preceding(Int)
    /// The current row.
    case currentRow
    /// `n` rows forward from the current one.
    case following(Int)

    var sql: String {
        switch self {
        case .unboundedPreceding: "UNBOUNDED PRECEDING"
        case .preceding(let n): "\(n) PRECEDING"
        case .currentRow: "CURRENT ROW"
        case .following(let n): "\(n) FOLLOWING"
        }
    }

    /// Declared only to be unavailable: without it the mistake is "type
    /// 'FrameStart' has no member", which is true and unhelpful.
    @available(
        *, unavailable,
        message: """
            A frame cannot start at UNBOUNDED FOLLOWING — Postgres rejects it with
            "frame start cannot be UNBOUNDED FOLLOWING". A frame starts at or before
            it ends: use .unboundedPreceding, .preceding(n), .currentRow or
            .following(n), and put UNBOUNDED FOLLOWING on the `to:` side.
            """
    )
    public static var unboundedFollowing: FrameStart { fatalError("unavailable") }
}

/// Where a frame ends. See ``FrameStart`` for why the two are different types.
public enum FrameEnd: Sendable {
    case preceding(Int)
    case currentRow
    case following(Int)
    /// Every row to the end of the partition.
    case unboundedFollowing

    var sql: String {
        switch self {
        case .preceding(let n): "\(n) PRECEDING"
        case .currentRow: "CURRENT ROW"
        case .following(let n): "\(n) FOLLOWING"
        case .unboundedFollowing: "UNBOUNDED FOLLOWING"
        }
    }

    /// See ``FrameStart/unboundedFollowing``: the mirror mistake, and the
    /// mirror message.
    @available(
        *, unavailable,
        message: """
            A frame cannot end at UNBOUNDED PRECEDING — Postgres rejects it with
            "frame end cannot be UNBOUNDED PRECEDING". A frame ends at or after it
            starts: use .preceding(n), .currentRow, .following(n) or
            .unboundedFollowing, and put UNBOUNDED PRECEDING on the `from:` side.
            """
    )
    public static var unboundedPreceding: FrameEnd { fatalError("unavailable") }
}

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

    /// `ROWS BETWEEN … AND …` — a frame counted in physical rows.
    ///
    /// This is what a moving average needs, and the reason it could not be
    /// written before: without a frame a window is the whole partition, so
    /// `avg()` over it is one number repeated, not a trailing average.
    ///
    /// ```swift
    /// // The average of this row and the two before it.
    /// p.viewCount.avg().over {
    ///     $0.order(p.createdAt.asc()).rows(from: .preceding(2))
    /// }
    /// ```
    ///
    /// The end defaults to the current row, which is what "so far" means in
    /// a running total or trailing average.
    public func rows(from start: FrameStart, to end: FrameEnd = .currentRow) -> Window {
        framed("ROWS", start, end)
    }

    /// `RANGE BETWEEN … AND …` — a frame counted in *peers*, meaning rows the
    /// window's `ORDER BY` cannot tell apart.
    ///
    /// With ties this differs from ``rows(from:to:)``: `ROWS` takes the row
    /// physically before, `RANGE` takes every row sharing the current one's
    /// ordering value. An offset here is an offset in the ordering column's
    /// own units, so Postgres requires exactly one `ORDER BY` column for it.
    public func range(from start: FrameStart, to end: FrameEnd = .currentRow) -> Window {
        framed("RANGE", start, end)
    }

    private func framed(_ mode: String, _ start: FrameStart, _ end: FrameEnd) -> Window {
        var copy = self
        // Offsets render literally, like LIMIT and OFFSET and for the same
        // reason: they are Ints this package writes into the statement, never
        // a caller's value reaching the text. A negative one is rejected by
        // Postgres ("frame starting offset must not be negative").
        copy.specification.frame = "\(mode) BETWEEN \(start.sql) AND \(end.sql)"
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
