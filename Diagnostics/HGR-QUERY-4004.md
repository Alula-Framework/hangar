# HGR-QUERY-4004: Fetching a grouped query as whole rows

**Severity:** error

## Meaning

`repo.all(...)` or `repo.one(...)` is given a query that has a `groupBy`.

## Why Hangar rejects it

GROUP BY collapses rows into groups, so there are no whole rows left to
decode. Postgres answers "column ... must appear in the GROUP BY clause or be
used in an aggregate function". A grouped query's result type is `Grouped<M>`,
which decodes as nothing, and `Repo`'s unavailable overloads say so.

## Fixes

1. Choose the columns: `.select(into: Summary.self) { ($0.customerID, $0.total.sum()) }`.
2. Ask about the groups instead: `repo.count(query)` or `repo.exists(query)`.

## Example

```swift
struct Spend: Decodable, Sendable { let customerID: UUID; let total: Int }
try await repo.all(Order.groupBy { $0.customerID }
    .select(into: Spend.self) { ($0.customerID, $0.total.sum()) })
```

## Related

HGR-QUERY-4001.
