# HGR-QUERY-4114: An undefined column or table: the database may be behind its migrations

**Severity:** a hint on a `DatabaseError` (SQLSTATE 42703 or 42P01)

## Meaning

Postgres reported that a column (42703) or table (42P01) the statement
names does not exist. The `DatabaseError` and the failure log carry this code
as a hint.

## Why Hangar reports it

In an application's own statements this is rarely a typo that compiled —
an `@Entity` names its columns from Swift. Far more often the entity was
changed and the migration that adds the column or table has not run against
this database: a new deployment, a test database, a replica.

## Fixes

1. Run the application's migrations against this database, and check they succeeded.
2. If migrations are current, compare the entity with the table: a renamed property, or an `@Column("…")` name that differs from the database's.
3. For raw SQL, check the statement's spelling — the server's message, in the error, names what it could not find.

## Related

HGR-QUERY-4106.
