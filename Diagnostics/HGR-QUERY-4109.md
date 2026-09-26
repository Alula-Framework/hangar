# HGR-QUERY-4109: An association was read without being preloaded

**Severity:** error (when the query runs)

## Meaning

`Loadable.get` was called on an association the query that fetched the
model did not preload.

## Why Hangar reports it

Hangar never loads an association lazily behind your back: a hidden query
per row is the N+1 problem, and a failure there would surface far from its
cause.

## Fixes

1. Add `.preload(\.association)` to the query that fetched the model.
2. Or query the associated rows yourself where you need them.
