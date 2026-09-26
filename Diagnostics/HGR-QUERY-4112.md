# HGR-QUERY-4112: A dynamic filter named a field outside the allowlist

**Severity:** error (when the query runs); the caller's input

## Meaning

A filter from a request named a field that is not in the entity's
`filterable` table.

## Why Hangar reports it

Only allowlisted columns are reachable from outside the program; anything
else is refused, never interpolated. This is the caller's mistake, not the
server's: `HangarError.isClientInput` is true, and an HTTP layer answers 400.

## Fixes

1. For the caller: use one of the documented filter fields.
2. For the application: add the column to `filterable` if it should be filterable.

## Related

HGR-QUERY-4113, HGR-QUERY-4006.
