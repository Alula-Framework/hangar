import Foundation

// Reporting expressions (Relay #14): what a dashboard query needs beyond
// columns — grouping by a computed value, time arithmetic, an aggregate over
// some of the rows, percentiles, and ordering by any of them.
//
//     // Incidents per day, and the median minutes to acknowledge the
//     // critical ones, busiest days first:
//     Incident.groupBy { $0.openedAt.truncated(to: .day) }
//         .select(into: DailyTrend.self) {
//             (day: $0.openedAt.truncated(to: .day),
//              opened: $0.id.count(),
//              criticalMTTA: $0.acknowledgedAt.interval(since: $0.openedAt).seconds
//                  .percentile(0.5).filter($0.severity == 1))
//         }
//         .order { $0.id.count().desc() }

// MARK: - Ordering by an expression

extension ColumnExpression {
    /// Order ascending by this expression.
    public func asc() -> OrderTerm { OrderTerm(expression: expression, direction: .asc) }
    /// Order descending by this expression.
    public func desc() -> OrderTerm { OrderTerm(expression: expression, direction: .desc) }
}

extension SelectExpression {
    /// Order ascending by this aggregate — in a grouped query, or a window's
    /// `ORDER BY` (`rank().over(.order(by: $0.id.count().desc()))`).
    public func asc() -> OrderTerm { OrderTerm(expression: expression, direction: .asc) }
    /// Order descending by this aggregate.
    public func desc() -> OrderTerm { OrderTerm(expression: expression, direction: .desc) }
}

// MARK: - Grouping by an expression

extension Query {
    /// Appends a GROUP BY expression — a truncated timestamp, arithmetic.
    ///
    /// Select the same expression to read the group's value. Postgres matches
    /// a selected expression to a grouped one by its text, so an expression
    /// with a bound value (`$0.score / 10`) renders a different placeholder in
    /// each place and does not match; ``RowValue/truncated(to:in:)`` renders
    /// its unit as SQL for exactly this reason.
    public func groupBy<V>(_ build: (Model.QueryColumns) -> ColumnExpression<V>) -> Query<
        Model, Grouped<Model>
    >
    where Result == Model {
        retypedForGrouping(adding: build(Model.queryColumns).expression)
    }

    /// Chaining a GROUP BY expression onto an already-grouped query.
    public func groupBy<V>(_ build: (Model.QueryColumns) -> ColumnExpression<V>) -> Query<
        Model, Grouped<Model>
    >
    where Result == Grouped<Model> {
        retypedForGrouping(adding: build(Model.queryColumns).expression)
    }
}

extension Table {
    /// `Self.groupBy { }` over an expression — sugar for `all.groupBy { }`.
    public static func groupBy<V>(_ build: (QueryColumns) -> ColumnExpression<V>) -> Query<
        Self, Grouped<Self>
    > {
        all.groupBy(build)
    }
}

// MARK: - Time

/// The units `date_trunc` rounds a timestamp down to.
public enum TimestampUnit: String, Sendable {
    case minute, hour, day, week, month, quarter, year
}

/// A timestamp value, optional or not — what time arithmetic accepts.
public protocol SQLTimestamp: Sendable {}
extension Date: SQLTimestamp {}
extension Optional: SQLTimestamp where Wrapped == Date {}

extension RowValue where Value: SQLTimestamp {
    /// `date_trunc('day', column)`: the timestamp rounded down to `unit`.
    ///
    /// The unit, and the time zone when given, render as SQL literals rather
    /// than binds, so grouping by this and selecting it produce the same
    /// text — which is how Postgres knows the selected value is the group's.
    /// Without a time zone the rounding happens in the session's `TimeZone`
    /// setting; days and weeks begin at its midnight.
    public func truncated(to unit: TimestampUnit, in timeZone: TimeZone? = nil) -> ColumnExpression<Value> {
        var arguments: [SQLExpression] = [.fragment([.sql("'\(unit.rawValue)'")]), _rowExpression.expression]
        if let timeZone, let zone = Self.literalZone(timeZone.identifier) {
            arguments.append(.fragment([.sql(zone)]))
        } else if let timeZone {
            // An identifier with characters no zone name has cannot be
            // written as a literal; bind it. Grouping and selecting it then
            // differ, but the value is never SQL text.
            arguments.append(.bind(SQLBind(timeZone.identifier)))
        }
        return ColumnExpression(expression: .function("date_trunc", arguments))
    }

    /// A zone identifier as a quoted literal, when it is only the characters
    /// zone names are made of.
    static func literalZone(_ identifier: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/_+-"))
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return nil }
        return "'\(identifier)'"
    }
}

extension RowValue where Value: SQLTimestamp {
    /// `self - earlier`: the interval between two timestamps, computed by the
    /// server — `$0.acknowledgedAt.interval(since: $0.openedAt)`. `nil` when
    /// either side is NULL. `.seconds` turns it into a number to average.
    public func interval(since earlier: some RowValue<some SQLTimestamp>) -> ColumnExpression<PostgresInterval?> {
        ColumnExpression(expression: .infix("-", _rowExpression.expression, earlier._rowExpression.expression))
    }
}

extension ColumnExpression where Value == PostgresInterval? {
    /// The interval in seconds, as `Double` — what `avg`, `percentile` and
    /// comparisons want: `date_part('epoch', interval)`, which is `float8`.
    public var seconds: ColumnExpression<Double?> {
        ColumnExpression<Double?>(expression: .function("date_part", [.fragment([.sql("'epoch'")]), expression]))
    }
}

// MARK: - Aggregates over expressions

extension ColumnExpression {
    /// `count(expression)`: how many rows have a non-NULL value.
    public func count() -> SelectExpression<Int> {
        SelectExpression(expression: .function("count", [expression]))
    }
}

extension ColumnExpression where Value == Double? {
    /// `avg(expression)`. NULLs are skipped; NULL when no row has a value.
    public func avg() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("avg", [expression]), "float8"))
    }
    /// `sum(expression)`.
    public func sum() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("sum", [expression]), "float8"))
    }
    /// `min(expression)`.
    public func min() -> SelectExpression<Double?> {
        SelectExpression(expression: .function("min", [expression]))
    }
    /// `max(expression)`.
    public func max() -> SelectExpression<Double?> {
        SelectExpression(expression: .function("max", [expression]))
    }
}

extension ColumnExpression where Value: SQLArithmetic {
    /// `avg(expression)`, as `Double`. NULL over zero rows.
    public func avg() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("avg", [expression]), "float8"))
    }
    /// `sum(expression)`, as `Double` — an expression's sum is not
    /// guaranteed to fit the operands' integer type. NULL over zero rows.
    public func sum() -> SelectExpression<Double?> {
        SelectExpression(expression: .cast(.function("sum", [expression]), "float8"))
    }
    /// `min(expression)`. NULL over zero rows.
    public func min() -> SelectExpression<Value?> {
        SelectExpression(expression: .function("min", [expression]))
    }
    /// `max(expression)`. NULL over zero rows.
    public func max() -> SelectExpression<Value?> {
        SelectExpression(expression: .function("max", [expression]))
    }
}

// MARK: - Ordered-set aggregates

/// A number, optional or not — what percentiles accept.
public protocol SQLNumeric: Sendable {}
extension Int: SQLNumeric {}
extension Int16: SQLNumeric {}
extension Int32: SQLNumeric {}
extension Int64: SQLNumeric {}
extension Double: SQLNumeric {}
extension Float: SQLNumeric {}
extension Decimal: SQLNumeric {}
extension Optional: SQLNumeric where Wrapped: SQLNumeric {}

extension RowValue where Value: SQLNumeric {
    /// `percentile_cont(fraction) WITHIN GROUP (ORDER BY value)`: the value
    /// below which `fraction` of the rows fall, interpolated between the two
    /// nearest. `percentile(0.5)` is the median; `0.95` the p95. NULLs are
    /// skipped; NULL when no row has a value.
    ///
    /// The fraction is bound. It must be between 0 and 1, or Postgres
    /// refuses the statement (SQLSTATE 22003).
    public func percentile(_ fraction: Double) -> SelectExpression<Double?> {
        SelectExpression(
            expression: .withinGroup(
                "percentile_cont", [.cast(.bind(SQLBind(fraction)), "float8")],
                .cast(_rowExpression.expression, "float8")))
    }

    /// The median: `percentile(0.5)`.
    public func median() -> SelectExpression<Double?> { percentile(0.5) }
}

// MARK: - FILTER

extension SelectExpression {
    /// The aggregate over only the rows `condition` admits:
    /// `count(*) FILTER (WHERE status = 'resolved')`.
    ///
    /// ```swift
    /// Incident.groupBy { $0.teamID }.select(into: TeamLoad.self) {
    ///     (teamID: $0.teamID,
    ///      open: $0.id.count().filter($0.status == .open),
    ///      resolved: $0.id.count().filter($0.status == .resolved))
    /// }
    /// ```
    ///
    /// A second `filter` narrows further: both conditions must hold.
    public func filter(_ condition: some PredicateConvertible) -> SelectExpression<Value> {
        SelectExpression(expression: Self.filtered(expression, condition.predicate.expression))
    }

    /// The filter goes on the aggregate call itself, inside the cast Hangar
    /// adds for decoding — `(sum(x) FILTER (WHERE …))::bigint`, not
    /// `(sum(x))::bigint FILTER …`, which is a syntax error.
    static func filtered(_ expression: SQLExpression, _ condition: SQLExpression) -> SQLExpression {
        switch expression {
        case .cast(let inner, let type):
            return .cast(filtered(inner, condition), type)
        case .aggregateFilter(let aggregate, let existing):
            return .aggregateFilter(aggregate, .infix("AND", existing, condition))
        default:
            return .aggregateFilter(expression, condition)
        }
    }
}
