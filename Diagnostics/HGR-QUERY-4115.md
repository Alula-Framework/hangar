# HGR-QUERY-4115: EXPLAIN ANALYZE of a statement that may write

**Severity:** error (when the query runs)

## Meaning

`repo.explain(_:mode: .analyze)` was given a statement that is not certainly a
read. Only `SELECT`, `VALUES`, `TABLE`, and a `WITH` with no `INSERT`,
`UPDATE`, `DELETE` or `MERGE` in it count as reads. Anything else counts as a
write: `SELECT … INTO`, a `SELECT` with `FOR UPDATE` or `FOR SHARE` written
into a fragment, `EXECUTE`, and a statement Hangar cannot read with
certainty, such as one with a dollar-quoted string.

## Why Hangar rejects it

`EXPLAIN ANALYZE` runs the statement it explains. Explaining a `DELETE` with
`.analyze` would delete the rows, and a data-modifying CTE runs to completion
even when the outer `SELECT` never reads it. `explain` is a diagnostic, so it
refuses before anything is sent rather than perform a write you asked it to
describe.

A typed query is checked the same way, because a raw CTE body passed to
`with(_:as:)` can hold a write. Its own row lock is not a write: a
`lockForUpdate()` query analyzes, and its plan comes from the primary.

## Fixes

1. For the plan alone, use `.plan`, the default. A write's plan is allowed and
   comes from the primary, not a read replica.
2. To measure the write, run `EXPLAIN ANALYZE` yourself inside a transaction
   that you roll back:

```swift
do {
    try await repo.transaction { tx in
        let rows = try await tx.execute(
            "EXPLAIN (ANALYZE, BUFFERS) DELETE FROM \(raw: "orders") WHERE placed_at < \(cutoff)")
        var plan: [String] = []
        for try await line in rows.decode(String.self) { plan.append(line) }
        throw RollbackError.intentional(plan.joined(separator: "\n"))
    }
} catch RollbackError.intentional(let plan) {
    print(plan)     // the DELETE ran, and was rolled back
}
```

## Related

HGR-QUERY-4111.
