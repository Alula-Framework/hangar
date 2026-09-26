# HGR-QUERY-4102: No ambient repo on this task

**Severity:** error (when the query runs)

## Meaning

`Repo.current` was read on a task where no repo was bound.

## Why Hangar reports it

The ambient repo is a task-local. It reaches structured child tasks, but not
`Task.detached` or a task started from outside the request that bound it.

## Fixes

1. Wrap the work in `Repo.with(repo) { … }`.
2. Or hand the detached task a `Repo` explicitly instead of reading the ambient one.
