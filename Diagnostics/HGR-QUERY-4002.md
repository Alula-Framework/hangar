# HGR-QUERY-4002: A window function compared in WHERE or HAVING

**Severity:** error

## Meaning

A window expression — `rowNumber()`, `rank()`, `lag(...)` with `over(...)` —
is compared as though it were a column in a filter.

## Why Hangar rejects it

Postgres rejects it: "window functions are not allowed in WHERE". A window is
computed after WHERE and HAVING have already chosen the rows, so it cannot
decide which rows they choose. `WindowExpression` has no comparison operators
for exactly that reason; the unavailable ones exist to say so.

## Fixes

1. Select the window value, put that query in a CTE with `.with(...)`, and
   compare the resulting column in the outer query.

## Example

```swift
// "the latest order per customer"
let ranked = Order.select {
    ($0.id, rowNumber().over(.partition(by: $0.customerID).order(by: $0.createdAt.desc())))
}
// … then, in the outer query over `ranked`: where rank == 1
```

## Related

HGR-QUERY-4001, HGR-QUERY-4003.
