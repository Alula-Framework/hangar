# HGR-QUERY-4110: A row stream was read after its `stream { }` call returned

**Severity:** error (when the query runs)

## Meaning

A `PostgresRowStream` was iterated after the closure it was handed to
returned.

## Why Hangar reports it

The stream holds a pooled connection for exactly the duration of the
closure. Once it returns, the connection is back in the pool and the rows are
gone.

## Fixes

1. Consume the stream inside the closure.
2. To keep rows, collect them inside the closure — or use `all`, or page with `limit`/`offset`.
