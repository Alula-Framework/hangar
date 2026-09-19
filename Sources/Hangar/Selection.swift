import Foundation
import PostgresNIO

// Projections: `.select {}` changes a query's Result type.
// Fetching three columns instead of thirty is a real, common win, and the
// typed tuple variant is the parameter-pack territory — see
// `Query.select` below for the spike's resolution.

/// An opaque SELECT-list fragment: public so `Selectable` can require it,
/// internal inside so the expression tree stays a Hangar implementation
/// detail. Not user-constructible.
public struct SelectFragment: Sendable {
    let expression: SQLExpression
}

/// Anything that can appear in a SELECT list with a known decoded type:
/// a bare `Column<V>`, or an aggregate/derived `SelectExpression<V>`.
public protocol Selectable<Value>: Sendable {
    associatedtype Value
    var _selectFragment: SelectFragment { get }
}

extension Column: Selectable {
    /// A bare column selects itself — not user API.
    public var _selectFragment: SelectFragment { SelectFragment(expression: expression) }
}

/// A derived SELECT-list expression — aggregates today, arbitrary SQL
/// functions later. `Value` is what one cell of it decodes to.
public struct SelectExpression<Value>: Sendable, Selectable {
    let expression: SQLExpression

    /// The expression as a SELECT-list item — not user API.
    public var _selectFragment: SelectFragment { SelectFragment(expression: expression) }
}

// MARK: - Aggregates
//
// Return types are chosen so decoding never hits the NUMERIC problem the
// flight-data-postgres spike catalogued (S3): Postgres widens integer
// sum/avg to NUMERIC, which PostgresNIO won't decode as Int/Double — so
// integer sums render as `(sum(x))::bigint` and averages as
// `(avg(x))::float8`. Aggregates over zero rows are SQL NULL, hence the
// optionals; `count` alone is total.

extension Column {
    /// `count(column)` — how many rows have a non-NULL value here. Total
    /// even over zero rows, which is why this one aggregate is non-optional.
    public func count() -> SelectExpression<Int> {
        SelectExpression(expression: .function("count", [expression]))
    }
}

extension Column where Value: BinaryInteger {
    /// `sum(column)` for integer columns, cast to `bigint` so the NUMERIC
    /// Postgres widens to decodes as `Int`. NULL over zero rows.
    public func sum() -> SelectExpression<Int?> {
        SelectExpression(expression: .cast(.function("sum", [expression]), "bigint"))
    }

    /// `avg(column)` for integer columns, cast to `float8` for the same
    /// NUMERIC reason as `sum`. NULL over zero rows.
    public func avg() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("avg", [expression]), "float8"))
    }
}

extension Column where Value: BinaryFloatingPoint {
    /// `sum(column)` for floating-point columns. NULL over zero rows.
    public func sum() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("sum", [expression]), "float8"))
    }

    /// `avg(column)` for floating-point columns. NULL over zero rows.
    public func avg() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("avg", [expression]), "float8"))
    }
}

extension Column where Value: Comparable & ColumnCodable {
    /// `min(column)`. NULL over zero rows.
    public func min() -> SelectExpression<Value?> {
        SelectExpression(expression: .function("min", [expression]))
    }

    /// `max(column)`. NULL over zero rows.
    public func max() -> SelectExpression<Value?> {
        SelectExpression(expression: .function("max", [expression]))
    }
}

// MARK: - Aggregate comparisons (for `having`, )

/// Aggregate equality, for `having` — `$0.id.count() == 3`.
public func == <V: ColumnCodable & Equatable>(lhs: SelectExpression<V>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// Aggregate comparison, for `having` — `$0.viewCount.sum() > 1_000`.
public func > <V: ColumnCodable & Comparable>(lhs: SelectExpression<V>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// Aggregate comparison, for `having`.
public func >= <V: ColumnCodable & Comparable>(lhs: SelectExpression<V>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

/// Aggregate comparison, for `having`.
public func < <V: ColumnCodable & Comparable>(lhs: SelectExpression<V>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// Aggregate comparison, for `having`.
public func <= <V: ColumnCodable & Comparable>(lhs: SelectExpression<V>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

// Nullable aggregates (sum/avg/min/max) compare against non-nil values;
// SQL's NULL comparison semantics (never true) carry through unchanged.
/// Nullable-aggregate equality: SQL NULL compares as never-true, unchanged.
public func == <V: ColumnCodable & Equatable>(lhs: SelectExpression<V?>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// Nullable-aggregate comparison: SQL NULL compares as never-true, unchanged.
public func > <V: ColumnCodable & Comparable>(lhs: SelectExpression<V?>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// Nullable-aggregate comparison: SQL NULL compares as never-true, unchanged.
public func >= <V: ColumnCodable & Comparable>(lhs: SelectExpression<V?>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

/// Nullable-aggregate comparison: SQL NULL compares as never-true, unchanged.
public func < <V: ColumnCodable & Comparable>(lhs: SelectExpression<V?>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// Nullable-aggregate comparison: SQL NULL compares as never-true, unchanged.
public func <= <V: ColumnCodable & Comparable>(lhs: SelectExpression<V?>, rhs: V)
    -> AggregatePredicate
{
    AggregatePredicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

// MARK: - The selection a query carries

/// How a projected query renders its SELECT list and decodes each row —
/// installed by `.select {}`, which is what changes `Result`. `items`
/// carry optional aliases (`expr AS "name"`, used by `select(into:)`).
/// `invalid` records a malformed `select(into:)` tuple; the `Repo` throws
/// it before anything reaches the wire (thrown, not trapped).
struct Selection<Result>: Sendable {
    let items: [(expression: SQLExpression, alias: String?)]
    let invalid: HangarError?
    let decode: @Sendable (PostgresRow) throws -> Result

    init(
        items: [(expression: SQLExpression, alias: String?)],
        invalid: HangarError? = nil,
        decode: @escaping @Sendable (PostgresRow) throws -> Result
    ) {
        self.items = items
        self.invalid = invalid
        self.decode = decode
    }
}
