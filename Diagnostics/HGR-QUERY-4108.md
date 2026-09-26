# HGR-QUERY-4108: A database enum value the Swift enum has no case for

**Severity:** error (when the query runs)

## Meaning

Postgres returned an enum label the Swift `PostgresEnum` does not declare.

## Why Hangar reports it

The database enum gained a value — by a migration, or another service —
and this build does not know it. Guessing a case would misreport the data.

## Fixes

1. Add the case to the Swift enum and deploy.
2. Deploy code that knows a new value before the migration that starts writing it.

## Related

HGR-QUERY-4107.
