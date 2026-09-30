# HGR-QUERY-4007: A join whose two sides have the same name

**Severity:** error (when the query runs)

## Meaning

Two sides of a join expose the same name in `FROM`. Usually this is a
self-join with no alias: `Employee.join(Employee.self, on: …)` names both
sides `employees`. It also happens when two aliases are the same string.

## Why Hangar rejects it

Every column in the statement is qualified with its side's name, so with two
sides called `employees`, `"employees"."id"` could mean either. Postgres
refuses it ("table name specified more than once"). Hangar reports it with
this code before anything is sent.

It is not a build error: a type cannot say that two generic parameters must
differ, so `Employee.join(Employee.self, …)` compiles.

## Fixes

1. Alias at least one side of a self-join. Aliasing both reads best:

```swift
Employee.alias("manager").join(Employee.alias("report"),
    on: { manager, report in report.managerID == manager.id })
```

2. If two aliases collide, rename one.

## Related

HGR-QUERY-4005.
