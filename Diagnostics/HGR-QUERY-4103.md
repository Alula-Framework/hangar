# HGR-QUERY-4103: `one` matched more than one row

**Severity:** error (when the query runs)

## Meaning

`repo.one(query)` found two or more rows.

## Why Hangar reports it

`one` answers "the row", and picking the first of several would return an
arbitrary one — which row depends on the plan Postgres chose.

## Fixes

1. If several rows are expected, use `all` (with an `order` and a `limit` if you want the first).
2. If only one should exist, narrow the predicate — and consider a unique constraint, so the database enforces it.
