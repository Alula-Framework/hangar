# HGR-QUERY-4105: Soft delete asked of an entity without a soft-delete column

**Severity:** error (when the query runs)

## Meaning

`softDelete` or `restore` was called for an entity with no `@Deleted`
column.

## Why Hangar reports it

A soft delete and a hard delete are not interchangeable, so Hangar refuses
rather than quietly removing the row.

## Fixes

1. Mark an optional `Date` property `@Deleted` and add the column in a migration.
2. Or use `forceDelete` to remove the row.
