# HGR-QUERY-4101: The transaction was rolled back, not committed

**Severity:** error (when the query runs)

## Meaning

A statement inside `transaction { }` failed, the body caught the error and
carried on, and the transaction ended. Postgres had already aborted it at the
failed statement, so nothing in it was saved: the `COMMIT` was answered with
`ROLLBACK`. The error names the statement that failed first.

## Why Hangar reports it

Reporting success here would tell the caller its work was saved when none
of it was — the one outcome a transaction exists to rule out.

## Fixes

1. Run a statement that may fail inside a nested `transaction { }`. That is a savepoint: rolling back to it undoes only that statement and leaves the outer transaction healthy.
2. Or let the error propagate, so the whole transaction fails visibly.

## Example

```swift
try await repo.transaction { tx in
    try await tx.insert(order)
    do {
        try await tx.transaction { sp in try await sp.insert(coupon) }   // a savepoint
    } catch let error as DatabaseError where error.isUniqueViolation {
        // the order is still going to commit
    }
}
```

## Related

HGR-QUERY-4104.
