/// The expression tree behind predicates. Values are always `SQLBind`
/// parameters — a value can never become SQL text.
/// What a window function sees: which rows it groups with, and in what order.
///
/// Empty means `OVER ()` — every row of the result set, unordered, which is
/// how `count(*) OVER ()` becomes "how many rows matched" alongside each row.
struct WindowSpecification: Sendable {
    var partitions: [SQLExpression] = []
    var orderings: [OrderTerm] = []
    /// The frame clause, already rendered — `ROWS BETWEEN … AND …`. Built
    /// from ``FrameStart``/``FrameEnd``, which carry no caller values.
    var frame: String?
}

indirect enum SQLExpression: Sendable {
    /// A column reference. `table` renders only in multi-table scopes
    /// (correlated subqueries, joins) — the writer decides.
    case column(table: String, name: String)
    case bind(SQLBind)
    /// `(lhs op rhs)` — comparison, AND/OR, LIKE/ILIKE.
    case infix(String, SQLExpression, SQLExpression)
    /// `(lhs = ANY(rhs))` — the batched-preload membership test (design
    /// ): one bound array parameter, however many keys.
    case anyOf(SQLExpression, SQLExpression)
    /// `name(args...)` — aggregates and, later, arbitrary functions.
    case function(String, [SQLExpression])
    /// `expr OVER (PARTITION BY … ORDER BY …)`.
    ///
    /// A window is a property of *how a function reads the result set*, not of
    /// the function itself, which is why it wraps an expression rather than
    /// being a kind of function: `sum(x)` and `sum(x) OVER (…)` are the same
    /// call site answering two different questions.
    case window(SQLExpression, WindowSpecification)
    /// `(operand)::type` — dialect-accommodation casts (integer sum →
    /// bigint, avg → float8). The type string is always Hangar-authored,
    /// never user input.
    case cast(SQLExpression, String)
    /// `(lhs IN (SELECT...))` — an uncorrelated subquery. The
    /// rendered inner statement shares the outer writer's placeholder
    /// numbering.
    case inSubquery(SQLExpression, SubquerySQL)
    /// `EXISTS (SELECT 1...)` — a possibly-correlated subquery;
    /// rendered with qualified column references throughout, since inner
    /// and outer tables coexist in one scope.
    case existsSubquery(SubquerySQL)
    /// `(SELECT one-expression FROM ... WHERE ...)` in a SELECT list — a
    /// correlated scalar subquery. One row, one column, or NULL.
    case scalarSubquery(SubquerySQL)
    /// A safe raw fragment: literal SQL text interleaved
    /// with bound values — see `SQLFragment`.
    case fragment([SQLFragment.Part])
    /// `NOT (operand)`
    case not(SQLExpression)
    case isNull(SQLExpression)
    case isNotNull(SQLExpression)
}

/// A boolean SQL expression — what `where` accepts and operators produce.
/// Deliberately not `Bool`, which is why overloading `&&`/`||` on it resolves
/// cleanly against the standard library's short-circuiting operators
/// (the design; the overload question is pinned by PredicateSpikeTests).
public struct Predicate: Sendable {
    let expression: SQLExpression
}

/// A comparison against an aggregate — what `having` takes and `where` will
/// not.
///
/// Postgres rejects an aggregate in `WHERE`:
///
///     ERROR:  aggregate functions are not allowed in WHERE
///
/// `WHERE` chooses the rows that feed the aggregate, so it cannot also read
/// it. Keeping the two comparison results in different types is what makes
/// that a compile error here rather than a failed request: `sum() > 5` is an
/// `AggregatePredicate`, and `where` has no overload that accepts one except
/// the unavailable overload that explains the fix.
public struct AggregatePredicate: Sendable, HavingConvertible {
    let expression: SQLExpression

    /// Not user API — how `having` reads it.
    public var _havingPredicate: Predicate { Predicate(expression: expression) }
}

/// Anything `having` accepts: a plain predicate on a grouped column, or a
/// comparison against an aggregate.
public protocol HavingConvertible: Sendable {
    /// Not user API.
    var _havingPredicate: Predicate { get }
}

extension PredicateConvertible {
    /// Every plain predicate is a valid `HAVING` too — grouping columns may be
    /// compared there, and often are.
    public var _havingPredicate: Predicate { predicate }
}

/// Anything usable where a predicate is expected. `Predicate` itself
/// conforms, and so does `Column<Bool>` — which is what makes the bare
/// `Post.where { $0.published }` spelling work.
public protocol PredicateConvertible: Sendable, HavingConvertible {
    var predicate: Predicate { get }
}

extension Predicate: PredicateConvertible {
    /// A predicate is trivially predicate-convertible — identity.
    public var predicate: Predicate { self }
}

extension Column: HavingConvertible where Value == Bool {}

extension Column: PredicateConvertible where Value == Bool {
    /// A boolean column stands alone as a predicate: `.where { $0.published }`.
    public var predicate: Predicate { Predicate(expression: expression) }
}

// MARK: - Comparison operators

/// `column = value` — the value is always a bound parameter.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <> value`.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, .bind(SQLBind(rhs))))
}

/// Optional columns: comparing against `nil` renders `IS NULL` /
/// `IS NOT NULL` — never `= NULL`, which matches nothing.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: V?) -> Predicate {
    guard let rhs else { return Predicate(expression: .isNull(lhs.expression)) }
    return Predicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <> value` for an optional column; `!= nil` renders `IS NOT NULL`.
///
/// **SQL's answer, not Swift's.** Against a non-nil value this is `<>`, and
/// `NULL <> 'x'` is unknown, so rows where the column is NULL are *not*
/// returned — although `nil != "x"` is `true` in Swift. That is the same
/// three-valued logic `!(column == value)` follows, and Hangar keeps the two
/// consistent. To include the NULL rows, ask for it:
/// ``Column/isDistinct(from:)`` renders `IS DISTINCT FROM`.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: V?) -> Predicate {
    guard let rhs else { return Predicate(expression: .isNotNull(lhs.expression)) }
    return Predicate(expression: .infix("<>", lhs.expression, .bind(SQLBind(rhs))))
}

extension Column {
    /// `column IS DISTINCT FROM value` — inequality with Swift's answer for
    /// NULL: a NULL column *is* distinct from a value, so those rows are
    /// returned, where `!=` would drop them.
    public func isDistinct<V: ColumnCodable & Equatable>(from value: V?) -> Predicate where Value == V? {
        guard let value else { return Predicate(expression: .isNotNull(expression)) }
        return Predicate(expression: .infix("IS DISTINCT FROM", expression, .bind(SQLBind(value))))
    }

    /// `column IS NOT DISTINCT FROM value` — equality where NULL equals NULL
    /// and never equals a value: never unknown, so `!` of it is exact.
    public func isNotDistinct<V: ColumnCodable & Equatable>(from value: V?) -> Predicate where Value == V? {
        guard let value else { return Predicate(expression: .isNull(expression)) }
        return Predicate(expression: .infix("IS NOT DISTINCT FROM", expression, .bind(SQLBind(value))))
    }
}

/// `column < value`.
public func < <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column > value`.
public func > <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <= value`.
public func <= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column >= value`.
public func >= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

/// Ordering comparisons against an optional column, where the value being
/// compared is not itself optional.
///
/// "Deleted before this date", "closed after that one" — the columns holding
/// those answers are nullable because the thing may not have happened yet,
/// and ranging over them is ordinary work. Without these overloads it does
/// not compile, and the error the type checker produces for the near miss is
/// "failed to produce diagnostic for expression", which tells the caller
/// nothing at all.
///
/// The right-hand side is deliberately non-optional: `deletedAt < nil` has no
/// meaning in SQL, where NULL comparisons are never true. Rows whose column
/// is NULL simply do not match — which is what "deleted before the cutoff"
/// should mean for a row that was never deleted.

/// `column < value` for a nullable column. NULL rows never match.
public func < <V: ColumnCodable & Comparable>(lhs: Column<V?>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column > value` for a nullable column. NULL rows never match.
public func > <V: ColumnCodable & Comparable>(lhs: Column<V?>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <= value` for a nullable column. NULL rows never match.
public func <= <V: ColumnCodable & Comparable>(lhs: Column<V?>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column >= value` for a nullable column. NULL rows never match.
public func >= <V: ColumnCodable & Comparable>(lhs: Column<V?>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

// MARK: - Boolean combinators (the spike surface)

/// Both predicates — renders `(lhs AND rhs)`, fully parenthesized.
public func && (lhs: some PredicateConvertible, rhs: some PredicateConvertible) -> Predicate {
    Predicate(expression: .infix("AND", lhs.predicate.expression, rhs.predicate.expression))
}

/// Either predicate — renders `(lhs OR rhs)`, fully parenthesized.
public func || (lhs: some PredicateConvertible, rhs: some PredicateConvertible) -> Predicate {
    Predicate(expression: .infix("OR", lhs.predicate.expression, rhs.predicate.expression))
}

public prefix func ! (operand: some PredicateConvertible) -> Predicate {
    Predicate(expression: .not(operand.predicate.expression))
}

// MARK: - Column-to-column comparisons (correlated subqueries and joins)

/// Column-to-column equality — the join-condition shape: `c.postID == p.id`.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, rhs.expression))
}

/// Column-to-column inequality.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, rhs.expression))
}

// A nullable foreign key joined against a non-null primary key is the
// ordinary shape for an optional relationship (`reply.parentID == root.id`),
// and Swift will not unify `Column<V?>` with `Column<V>` on its own. SQL has
// no such distinction — `=` on a NULL yields NULL, which a JOIN or WHERE
// treats as "no match", exactly the intended reading.

/// Equality between a nullable column and a non-null one. A NULL on the
/// left never matches, which is what an optional relationship means.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, rhs.expression))
}

/// Equality between a non-null column and a nullable one.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V?>) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, rhs.expression))
}

/// Inequality between a nullable column and a non-null one.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, rhs.expression))
}

/// Inequality between a non-null column and a nullable one.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V?>) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, rhs.expression))
}

// Ordering between columns — "is the incoming version newer", a range join,
// `updated_at > created_at`.

/// `lhs < rhs`, column to column.
public func < <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("<", lhs.expression, rhs.expression))
}

/// `lhs > rhs`, column to column.
public func > <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix(">", lhs.expression, rhs.expression))
}

/// `lhs <= rhs`, column to column.
public func <= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("<=", lhs.expression, rhs.expression))
}

/// `lhs >= rhs`, column to column.
public func >= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix(">=", lhs.expression, rhs.expression))
}

// MARK: - Membership

extension Column where Value: ColumnCodable & PostgresArrayEncodable {
    /// Membership in a value list — rendered `= ANY($1)`: one bound array
    /// parameter, however many values.
    public func `in`(_ values: [Value]) -> Predicate {
        Predicate(expression: .anyOf(expression, .bind(SQLBind { try $0.append(values) })))
    }
}

extension Column {
    /// Membership in an uncorrelated subquery — because a query is a
    /// value, the inner SELECT nests with no special mechanism, and its
    /// binds share the outer statement's numbering:
    ///
    /// ```swift
    /// let activeAuthors = Author.where { $0.name != "" }.select { $0.id }
    /// Post.where { $0.authorID.in(activeAuthors) }
    /// ```
    ///
    /// The subquery's Result must match this column's type — enforced by
    /// the signature.
    public func `in`<M2: Table>(_ subquery: Query<M2, Value>) -> Predicate {
        Predicate(
            expression: .inSubquery(
                expression,
                SubquerySQL { writer in
                    SQLRenderer.selectText(subquery, writer: &writer)
                }))
    }
}

extension Query {
    /// This query as a correlated `EXISTS` predicate — the closure
    /// that built it may reference the *outer* query's columns, because a
    /// query is just an expression tree:
    ///
    /// ```swift
    /// Post.where { p in
    ///     Comment.where { $0.postID == p.id && $0.body != "" }.exists
    /// }
    /// ```
    ///
    /// Inside the EXISTS scope every column renders table-qualified, since
    /// inner and outer tables share one namespace.
    public func exists() -> Predicate {
        let query = self
        return Predicate(
            expression: .existsSubquery(
                SubquerySQL { writer in
                    SQLRenderer.existsText(query, writer: &writer)
                }))
    }
}

// MARK: - Pattern matching

/// Escapes text for use inside a `LIKE`/`ILIKE` pattern, so it matches
/// itself: `%`, `_` and the escape character `\` each gain a backslash.
///
/// Reach for it whenever part of a pattern comes from a user. Without it a
/// search box is a pattern language: `50%` finds `500`, `a_c` finds `abc`, and
/// a lone `%` matches every row. ``Column/contains(_:caseInsensitive:)`` and
/// its siblings apply it for you.
///
/// Backslash is Postgres's default `LIKE` escape, independent of
/// `standard_conforming_strings`, so no `ESCAPE` clause is needed.
public func likeEscaped(_ text: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(text.count)
    for character in text {
        if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
        escaped.append(character)
    }
    return escaped
}

private func patternMatch(_ column: SQLExpression, _ pattern: String, caseInsensitive: Bool) -> Predicate {
    Predicate(expression: .infix(caseInsensitive ? "ILIKE" : "LIKE", column, .bind(SQLBind(pattern))))
}

extension Column where Value == String {
    /// `column LIKE pattern` — `%` and `_` are wildcards, and so is any `%` or
    /// `_` inside text you interpolate. For user input use
    /// ``contains(_:caseInsensitive:)``, or escape it with ``likeEscaped(_:)``.
    public func like(_ pattern: String) -> Predicate {
        patternMatch(expression, pattern, caseInsensitive: false)
    }

    /// Postgres-only case-insensitive LIKE. The same caution about wildcards
    /// in interpolated text applies as for ``like(_:)``.
    public func ilike(_ pattern: String) -> Predicate {
        patternMatch(expression, pattern, caseInsensitive: true)
    }

    /// Rows whose value contains `text` literally — wildcards in it match
    /// only themselves. The safe way to put a search term in a pattern.
    public func contains(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "%\(likeEscaped(text))%", caseInsensitive: caseInsensitive)
    }

    /// Rows whose value starts with `text`, literally. A left-anchored
    /// `LIKE` can use a `text_pattern_ops` index.
    public func hasPrefix(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "\(likeEscaped(text))%", caseInsensitive: caseInsensitive)
    }

    /// Rows whose value ends with `text`, literally.
    public func hasSuffix(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "%\(likeEscaped(text))", caseInsensitive: caseInsensitive)
    }
}

extension Column where Value == String? {
    /// `column LIKE pattern` — `%` and `_` are wildcards. NULL never matches.
    public func like(_ pattern: String) -> Predicate {
        patternMatch(expression, pattern, caseInsensitive: false)
    }

    /// `column ILIKE pattern` — Postgres's case-insensitive LIKE.
    public func ilike(_ pattern: String) -> Predicate {
        patternMatch(expression, pattern, caseInsensitive: true)
    }

    /// Rows whose value contains `text` literally. NULL never matches.
    public func contains(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "%\(likeEscaped(text))%", caseInsensitive: caseInsensitive)
    }

    /// Rows whose value starts with `text`, literally. NULL never matches.
    public func hasPrefix(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "\(likeEscaped(text))%", caseInsensitive: caseInsensitive)
    }

    /// Rows whose value ends with `text`, literally. NULL never matches.
    public func hasSuffix(_ text: String, caseInsensitive: Bool = false) -> Predicate {
        patternMatch(expression, "%\(likeEscaped(text))", caseInsensitive: caseInsensitive)
    }
}

/// The `Result` of a grouped query that has not chosen its columns yet.
///
/// A `GROUP BY` collapses rows, so "give me the whole model" stops being a
/// question the database can answer:
///
///     ERROR:  column "title" must appear in the GROUP BY clause or be used
///             in an aggregate function
///
/// Grouping therefore changes the result type to this one, which nothing
/// decodes. `select(into:)` and `select(_:)` move it to a type that does, and
/// `count` and `exists` take it as it is — they ask about the groups, not the
/// columns. Fetching it whole is the one thing it will not do, and `Repo`
/// carries unavailable overloads that say so in those words.
public struct Grouped<Model: Table>: Sendable {}
