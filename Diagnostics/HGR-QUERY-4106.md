# HGR-QUERY-4106: A row does not have the columns the entity expects

**Severity:** error (when the query runs)

## Meaning

A row arrived with a different number of columns than the entity's decoder
reads.

## Why Hangar reports it

The statement's column list and the Swift type disagree — most often the
entity was changed and the SQL that fetches it was not, or a raw statement
selects its own columns into a whole entity.

## Fixes

1. For a raw statement, select exactly the entity's columns, in schema order — or project into a type that matches what you select.
2. If the entity changed, check the database has the matching migration.

## Related

HGR-QUERY-4107, HGR-QUERY-4114.
