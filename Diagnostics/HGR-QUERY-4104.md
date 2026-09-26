# HGR-QUERY-4104: The model's row no longer exists

**Severity:** error (when the query runs)

## Meaning

An update or delete of a specific model matched no row: its primary key no
longer identifies one.

## Why Hangar reports it

The row was deleted concurrently, or the model was never inserted. Writing
nothing and reporting success would lose the caller's change silently.

## Fixes

1. Treat it as a conflict: reload, and tell the caller the record is gone (often a 404 or 409).
2. If the model was built in memory, insert it rather than update it.

## Related

HGR-QUERY-4101.
