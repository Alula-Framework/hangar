# Reporting queries

Expressions the server computes per row, and the grouping, filtering and
percentiles a dashboard is made of.

## Overview

A column is the simplest thing a row can be asked for. A report usually
needs more: a price times a quantity, the day a timestamp falls on, the time
between two timestamps. Each of these is a ``ColumnExpression``, a typed
expression that the server computes for each row. The examples below use
this entity:

```swift
@Entity("incidents")
struct Incident {
    @ID var id: UUID
    var teamID: UUID
    var severity: Int16
    var status: String
    var version: Int
    var openedAt: Date
    var acknowledgedAt: Date?
    var updatedAt: Date
}
```

## Arithmetic is methods

`adding`, `subtracting`, `multiplied(by:)` and `divided(by:)` each take a
value, a column, or another expression, and return a ``ColumnExpression``
of the same type:

```swift
LineItem.where { $0.price.multiplied(by: $0.quantity) > 10_000 }
LineItem.where { $0.price.multiplied(by: $0.quantity).divided(by: 100) >= 50 }
```

There are no `+ - * /` overloads on columns. Generic ones doubled the time
Swift takes to type-check ordinary `Double` arithmetic in any file importing
Hangar, and overloads on the concrete column types were slower still. A
method costs nothing at call sites that do not use it.

The server computes in the column's type (see ``SQLArithmetic``). Integer
division truncates, dividing by zero is SQLSTATE 22012, and an integer
result too large for its type is SQLSTATE 22003 rather than a wrapped value.

## Expressions in a bulk update

An assignment can be an expression. It is rendered as SQL, not computed in
Swift and bound, so it reads each row as the statement updates it:

```swift
try await repo.update(Incident.where { $0.id == id }) {
    ($0.version.set(to: $0.version.adding(1)),       // SET version = (version + $1)
     $0.updatedAt.set(to: .transactionTimestamp))    // the server's now()
}
```

Twenty concurrent increments add twenty. ``ColumnExpression/transactionTimestamp``
is the transaction's start time on the server's clock, the same for every
row the statement touches. `.now` in the same position would be Foundation's
`Date.now`, computed and bound by the client. `set(to: $0.otherColumn)` copies
another column.

## Grouping by an expression

`groupBy` takes an expression as well as a column. The usual one is a
timestamp rounded down to a unit, with `truncated(to:in:)`:

```swift
struct DailyTrend: Decodable {
    let day: Date
    let opened: Int
    let critical: Int
    let medianAckSeconds: Double?
}

let utc = TimeZone(identifier: "UTC")!

let trend = try await repo.all(
    Incident.groupBy { $0.openedAt.truncated(to: .day, in: utc) }
        .select(into: DailyTrend.self) {
            (day: $0.openedAt.truncated(to: .day, in: utc),
             opened: $0.id.count(),
             critical: $0.id.count().filter($0.severity == 1),
             medianAckSeconds: $0.acknowledgedAt.interval(since: $0.openedAt).seconds.median())
        }
        .order { $0.openedAt.truncated(to: .day, in: utc).asc() })
```

Select the same expression to read the group's value. Postgres matches a
selected expression to a grouped one by its text, so `truncated(to:in:)`
writes its unit and time zone as SQL literals: the two render identically.
An expression with a bound value, such as `$0.severity.divided(by: 2)`,
renders a different placeholder in each place and does not match; Postgres
then asks for the column to appear in `GROUP BY`. Without a time zone, the
rounding happens in the session's `TimeZone` setting.

## Time between timestamps

`interval(since:)` subtracts one timestamp from another on the server and
returns a `PostgresInterval?`, which is `nil` when either side is NULL.
`.seconds` turns it into a `Double?`, which is what `avg`, `percentile` and
comparisons need:

```swift
$0.acknowledgedAt.interval(since: $0.openedAt).seconds.avg()
```

## An aggregate over some of the rows

`filter` on an aggregate adds Postgres's `FILTER (WHERE …)`, so one grouped
query can count several subsets side by side:

```swift
Incident.groupBy { $0.teamID }.select(into: TeamLoad.self) {
    (teamID: $0.teamID,
     open: $0.id.count().filter($0.status == "open"),
     resolved: $0.id.count().filter($0.status == "resolved"))
}
```

A second `filter` narrows further: both conditions must hold.

## Percentiles

`percentile(_:)` is `percentile_cont(fraction) WITHIN GROUP (ORDER BY …)`:
the value below which that fraction of the rows fall, interpolated between
the two nearest. `median()` is `percentile(0.5)`. Both skip NULLs and return
`Double?`:

```swift
p95AckSeconds: $0.acknowledgedAt.interval(since: $0.openedAt).seconds.percentile(0.95)
```

The fraction must be between 0 and 1, or Postgres refuses the statement.

Aggregates also take expressions: `$0.price.multiplied(by: $0.quantity).sum()`
is a `Double?`, because the sum of an expression is not guaranteed to fit the
operands' integer type.

## Ordering by an expression or an aggregate

`asc()` and `desc()` work on expressions and aggregates, in `order` and in a
window's `ORDER BY`:

```swift
Incident.groupBy { $0.teamID }
    .select(into: TeamRank.self) {
        (teamID: $0.teamID,
         incidents: $0.id.count(),
         place: rank().over(.order(by: $0.id.count().desc())))
    }
    .order { $0.id.count().desc() }
```

## One list from several tables

A feed that merges rows from different tables is a set operation over
projections. Each branch is a `select(into:)` of the same `Result` type, and
the combination is a ``CombinedQuery``:

```swift
struct FeedItem: Decodable {
    let at: Date
    let source: String
    let summary: String
}

let feed = Incident.all.select(into: FeedItem.self) {
        (at: $0.openedAt, source: ColumnExpression.value("incident"), summary: $0.status)
    }
    .unionAll(Deploy.all.select(into: FeedItem.self) {
        (at: $0.finishedAt, source: ColumnExpression.value("deploy"), summary: $0.service)
    })
    .order("at", .desc)
    .limit(50)

let items = try await repo.all(feed)
```

``ColumnExpression/value(_:)`` is a constant in every row, bound as a
parameter. Here it records which table a row came from. Write the type out:
the projection's tuple gives `.value` nothing to infer it from.

`union`, `unionAll`, `intersect` and `except` all combine this way. Postgres
pairs columns by position, not name, so a branch whose labels come in
another order is reordered to match the first, and a branch with different
labels is refused before anything runs. The combination is ordered by an
output column's name, limited and offset. It has no `where`, because the
branches are where rows are chosen. Chaining is parenthesised as it reads:
`a.union(b).intersect(c)` intersects the union, although `INTERSECT` binds
tighter in SQL.
