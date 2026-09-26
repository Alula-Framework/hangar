# HGR-QUERY-4113: A dynamic filter value of the wrong type

**Severity:** error (when the query runs); the caller's input

## Meaning

A filter value could not be read as its column's type: a string for an
integer column, a number out of a `smallint`'s range, a malformed UUID or
date.

## Why Hangar reports it

The value is refused rather than coerced or trapped on. `isClientInput` is
true, and an HTTP layer answers 400.

## Fixes

1. For the caller: send a value of the column's type — dates as ISO 8601, UUIDs in their standard form.

## Related

HGR-QUERY-4112.
