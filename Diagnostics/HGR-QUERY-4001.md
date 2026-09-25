# HGR-QUERY-4001: An aggregate in WHERE

**Severity:** error

## Meaning

A `where` closure compares an aggregate — `sum()`, `count()`, `avg()` — such
as `.where { $0.total.sum() > 100 }`.

## Why Hangar rejects it

Postgres rejects it: "aggregate functions are not allowed in WHERE". WHERE
chooses the rows that feed the aggregate, so it cannot also read the
aggregate's result. Hangar types an aggregate comparison as an
`AggregatePredicate`, which `where` does not accept, so the mistake is a build
error rather than a failed request.

## Fixes

1. Group the rows and filter the groups with `having`:
   `.groupBy { $0.customerID }.having { $0.total.sum() > 100 }`.
2. If you meant a per-row condition, compare the column itself:
   `.where { $0.total > 100 }`.

## Example

```swift
Order.groupBy { $0.customerID }.having { $0.total.sum() > 100 }
```

## Related

HGR-QUERY-4002, HGR-QUERY-4004.
