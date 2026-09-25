# HGR-QUERY-4005: A row lock combined with UNION, INTERSECT or EXCEPT

**Severity:** error (when the query runs)

## Meaning

A query with `lockForUpdate()`, `lockForShare()` or `lock(_:)` was combined
with `union`, `unionAll`, `intersect` or `except` — either a locked branch, or
a lock on the combination itself.

## Why Hangar rejects it

Postgres refuses it: "FOR UPDATE is not allowed with UNION/INTERSECT/EXCEPT".
A lock applies to rows of a table, and a combination's rows belong to no one
table. Hangar reports it before anything reaches the server, with this code,
when the query runs.

This one is not a build error: a lock and a combination are both ordinary
query values, and telling them apart in the type would split every query type
in two. It used to be worse — a precondition that stopped the process.

## Fixes

1. Lock the rows in a separate statement inside the same transaction: select
   their ids with the lock, then run the combined query.
2. If the combination only needs to read, drop the lock.

## Example

```swift
try await repo.transaction { tx in
    let ids = try await tx.all(Job.where { $0.state == .ready }.select { $0.id }.lockForUpdate())
    let jobs = try await tx.all(Job.where { $0.id.in(ids) }.union(Job.where { $0.priority == .urgent }))
    …
}
```

## Related

HGR-QUERY-4001.
