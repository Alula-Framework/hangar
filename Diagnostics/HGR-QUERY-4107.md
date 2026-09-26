# HGR-QUERY-4107: A column did not decode as its property's type

**Severity:** error (when the query runs)

## Meaning

A cell could not be read as the entity property's Swift type. The error
names the table and column.

## Why Hangar reports it

The column's database type and the property's Swift type disagree: an
`Int` property over a `bigint` that outgrew it, a non-optional property over
a column holding NULL, a `text` column read as a `UUID`.

## Fixes

1. Make the property's type match the column — optional if the column is nullable.
2. If the column's type changed, check the migration and the entity agree.

## Related

HGR-QUERY-4106, HGR-QUERY-4108.
