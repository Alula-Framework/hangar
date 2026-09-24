# ``Hangar``

A type-safe query layer for PostgreSQL, built directly on PostgresNIO.

## Overview

Models are structs, queries are values you compose, and columns are keypaths —
so a misspelled column is a compile error rather than a runtime one.

```swift
@Entity("posts")
struct Post {
    @ID var id: UUID
    @Column var title: String
    @Column var viewCount: Int
    @BelongsTo(\.authorID) var author: Loadable<Author>
}

let popular = try await repo.all(
    Post.where { $0.viewCount > 1_000 }
        .order { $0.viewCount.desc() }
        .limit(20)
        .preload(\.author)
)
```

## Queries are values

Nothing runs until a ``Repo`` executes it, so a query can be built in pieces,
passed around, stored, and reused. Composition never mutates what it was
composed from:

```swift
let base = Post.where { $0.published == true }
let recent = base.order { $0.createdAt.desc() }.limit(10)
let mine = base.where { $0.authorID == me }      // `base` is unchanged
```

That property is what makes a repository method safe to hand a partially-built
query without wondering who else holds it.

## Loud beats empty

An association that was never preloaded throws `HangarError.notPreloaded`
rather than returning nothing. An empty array is indistinguishable from "there
are none", and that ambiguity is exactly how an N+1 hides.

The same principle runs through the error type: every case names the fix, not
just the problem, because someone is usually reading it during an incident.

## Topics

### Defining models

- ``Table``
- ``Loadable``

### Building queries

- ``Query``
- ``JoinedQuery``
- ``JoinedQuery3``
- ``ComposedQuery``
- ``QueryBuilder``
- ``Aliased``
- ``CommonTableExpression``
- ``Predicate``
- ``DeletedRowScope``
- ``DynamicFilterValue``

### Running them

- ``Repo``
- ``IsolationLevel``
- ``Multi``
- ``PostgresRowStream``
- ``Page``
- ``PageRequest``
- ``ExplainMode``
- ``QueryDiagnostics``

### Errors

- ``DatabaseError``
- ``HangarError``
- ``DatabaseRows``

### Guides

- <doc:ComposedJoins>
- <doc:Preloading>
- <doc:TransactionsAndConnections>
