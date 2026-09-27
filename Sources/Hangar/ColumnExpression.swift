import Foundation

// Row-level expressions: arithmetic over columns, rendered as SQL.
//
// `$0.version.adding(1)` is a `ColumnExpression<Int>` — computed per row by the
// server, not a value computed in Swift and bound. It is what makes
// `SET version = version + 1` expressible (Relay #9): the increment happens
// inside the statement, under the row's lock, so two concurrent updates
// cannot both read 3 and both write 4.
//
// Kept apart from `SelectExpression`, which is what aggregates return: an
// aggregate cannot appear in `WHERE` or `SET`, and a row-level expression
// can, so the two compare into different predicate types.

/// A typed per-row SQL expression: `$0.version.adding(1)`, `$0.price.multiplied(by: $0.quantity)`,
/// `.transactionTimestamp`. `Value` is what it evaluates to. Usable in a bulk update's SET
/// (``Column/set(to:)-(ColumnExpression<Value>)``), in `where`, and in a
/// SELECT list.
public struct ColumnExpression<Value>: Sendable, Selectable {
    let expression: SQLExpression

    /// The expression as a SELECT-list item — not user API.
    public var _selectFragment: SelectFragment { SelectFragment(expression: expression) }
}

extension ColumnExpression where Value: ColumnCodable {
    /// A constant, the same in every row — bound as a parameter, never SQL
    /// text. Its use is a projection that labels where a row came from:
    ///
    /// ```swift
    /// TimelineEvent.all.select(into: FeedEntry.self) {
    ///     (at: $0.at, source: ColumnExpression.value("timeline"), kind: $0.kind)
    /// }
    /// .unionAll(ProviderEvent.all.select(into: FeedEntry.self) {
    ///     (at: $0.receivedAt, source: ColumnExpression.value("provider"), kind: $0.kind)
    /// })
    /// ```
    ///
    /// Write the type out: inside a projection's tuple there is no
    /// contextual type for `.value(…)` to be inferred from.
    public static func value(_ value: Value) -> ColumnExpression<Value> {
        ColumnExpression(expression: .bind(SQLBind(value)))
    }
}

extension ColumnExpression where Value == Date {
    /// `now()` — Postgres's `transaction_timestamp()`: the transaction's
    /// start time on the server's clock, the same value for every row a
    /// statement touches. (Not `.now`, which in a `Date` position is
    /// Foundation's, computed and bound by the client.)
    public static var transactionTimestamp: ColumnExpression<Date> {
        ColumnExpression(expression: .function("now", []))
    }
}

/// Anything that evaluates to a `Value` per row: a column, or an expression
/// over columns. Not user-conformable.
public protocol RowValue<Value>: Sendable {
    associatedtype Value
    var _rowExpression: ColumnExpression<Value> { get }
}

extension Column: RowValue {
    /// Not user API.
    public var _rowExpression: ColumnExpression<Value> { ColumnExpression(expression: expression) }
}

extension ColumnExpression: RowValue {
    /// Not user API.
    public var _rowExpression: ColumnExpression<Value> { self }
}

// MARK: - Arithmetic

/// The arithmetic `Value` types: integers, floating point, `Decimal`. The
/// server computes in the column's type, so integer division truncates as
/// Swift's does, and an integer result too large for the column fails with
/// SQLSTATE 22003 rather than wrapping.
public protocol SQLArithmetic: ColumnCodable {}
extension Int: SQLArithmetic {}
extension Int16: SQLArithmetic {}
extension Int32: SQLArithmetic {}
extension Int64: SQLArithmetic {}
extension Double: SQLArithmetic {}
extension Float: SQLArithmetic {}
extension Decimal: SQLArithmetic {}

// Methods, not `+ - * /`. Operator overloads were measured: generic ones
// doubled the time Swift takes to type-check ordinary `Double` arithmetic in
// any file that imports Hangar, and one test's plain arithmetic stopped
// type-checking at all; overloads on the concrete column types were worse
// still. A method costs nothing at call sites that do not use it.

extension RowValue where Value: SQLArithmetic {
    private func arithmetic(_ op: String, _ rhs: SQLExpression) -> ColumnExpression<Value> {
        ColumnExpression(expression: .infix(op, _rowExpression.expression, rhs))
    }

    /// `self + value`, computed by the server: `$0.version.adding(1)`.
    public func adding(_ value: Value) -> ColumnExpression<Value> { arithmetic("+", .bind(SQLBind(value))) }
    /// `self + other`, per row.
    public func adding(_ other: some RowValue<Value>) -> ColumnExpression<Value> {
        arithmetic("+", other._rowExpression.expression)
    }

    /// `self - value`, computed by the server.
    public func subtracting(_ value: Value) -> ColumnExpression<Value> { arithmetic("-", .bind(SQLBind(value))) }
    /// `self - other`, per row.
    public func subtracting(_ other: some RowValue<Value>) -> ColumnExpression<Value> {
        arithmetic("-", other._rowExpression.expression)
    }

    /// `self * value`, computed by the server.
    public func multiplied(by value: Value) -> ColumnExpression<Value> { arithmetic("*", .bind(SQLBind(value))) }
    /// `self * other`, per row: `$0.price.multiplied(by: $0.quantity)`.
    public func multiplied(by other: some RowValue<Value>) -> ColumnExpression<Value> {
        arithmetic("*", other._rowExpression.expression)
    }

    /// `self / value`, computed by the server. Integer division truncates;
    /// dividing by zero is SQLSTATE 22012.
    public func divided(by value: Value) -> ColumnExpression<Value> { arithmetic("/", .bind(SQLBind(value))) }
    /// `self / other`, per row.
    public func divided(by other: some RowValue<Value>) -> ColumnExpression<Value> {
        arithmetic("/", other._rowExpression.expression)
    }
}

// MARK: - Comparisons, for `where`

/// `expression = value`.
public func == <V: ColumnCodable & Equatable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `expression <> value`.
public func != <V: ColumnCodable & Equatable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, .bind(SQLBind(rhs))))
}

/// `expression > value`.
public func > <V: ColumnCodable & Comparable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// `expression >= value`.
public func >= <V: ColumnCodable & Comparable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `expression < value`.
public func < <V: ColumnCodable & Comparable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// `expression <= value`.
public func <= <V: ColumnCodable & Comparable>(lhs: ColumnExpression<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

// MARK: - Assignment

extension Column {
    /// `column = expression`, computed by the server for each row:
    ///
    /// ```swift
    /// try await repo.update(Incident.where { $0.id == id }) {
    ///     ($0.version.set(to: $0.version.adding(1)), $0.updatedAt.set(to: .transactionTimestamp))
    /// }
    /// ```
    ///
    /// Rendered as SQL, not bound: the increment reads the row as the
    /// statement updates it, so concurrent updates each add one.
    public func set(to expression: ColumnExpression<Value>) -> Assignment<Value> {
        Assignment(name: name, expression: expression.expression)
    }

    /// `column = other_column`, copied per row.
    public func set(to other: Column<Value>) -> Assignment<Value> {
        Assignment(name: name, expression: other.expression)
    }

    /// `column = expression` for an optional column, from a non-optional
    /// expression.
    public func set<V>(to expression: ColumnExpression<V>) -> Assignment<V?> where Value == V? {
        Assignment(name: name, expression: expression.expression)
    }
}
