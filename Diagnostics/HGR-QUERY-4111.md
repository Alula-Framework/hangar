# HGR-QUERY-4111: A bulk write was given a clause it cannot honour

**Severity:** error (when the query runs)

## Meaning

`delete(query)` or `update(query) { … }` was given a query with `LIMIT`,
`OFFSET`, `ORDER BY`, `GROUP BY`, `HAVING` or `DISTINCT`.

## Why Hangar reports it

`UPDATE` and `DELETE` take only a `WHERE`. Running the statement with the
clause dropped would write rows you did not ask for — a delete that ignores
your `LIMIT` deletes everything that matches.

## Fixes

1. Select the ids with the full query, then write `where { $0.id.in(ids) }`.
2. Or fetch the rows and write them one by one.
