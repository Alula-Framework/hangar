# Preloading associations

Loading related rows without N+1, and why an unloaded association throws.

## Overview

An association is declared on the model and loaded on demand:

```swift
@Entity("posts")
struct Post {
    @ID var id: UUID
    var authorID: UUID
    @BelongsTo(foreignKey: \Post.authorID) var author: Loadable<Author>
    @HasMany(foreignKey: \Comment.postID) var comments: Loadable<[Comment]>
}
```

```swift
let posts = try await repo.all(Post.all.preload(\.author).preload(\.comments))
```

## One query per association, not one per row

Preloading collects the keys from the parent rows and issues a single query
per association using `= ANY($1)` — one bound array, however many keys. Three
associations on a hundred posts is four queries, not three hundred and one.

Preloads run sequentially rather than concurrently, which is the safe default
but does mean three associations are three round trips.

> Note: Key sets are not chunked. A hundred thousand parents means a
> hundred-thousand-element bind, and that has not been measured past a
> thousand. If you are preloading over very large result sets, page the
> parents.

## Soft-deleted children

A preloaded association excludes the child's soft-deleted rows by default,
with no special case for preloading: every preload path runs `repo.all` on
an ordinary `Query<Child, Child>`, whose default scope already excludes
deleted rows, so the exclusion arrives for free rather than needing its own
logic to stay correct.

The tune closure is an ordinary query builder, so it opts back in the same
way any other scope change would:

```swift
Post.all.preload(\.files) { $0.withDeleted() }
```

## Preloading through a join

Preloads run after the parent rows decode, so they work on any read whose
result is the base entity — including a join. They apply to the base
entity, and `Query.join` carries them across the conversion:

```swift
Post.join(Comment.self, on: { p, c in c.postID == p.id })
    .preload(\.author)
```

``QueryBuilder`` has the same `preload` surface:

```swift
Post.query { q, post in
    _ = q.join(Author.self) { $0.id == post.authorID }
    q.distinct()
    q.preload(\.comments)
    return q.query()
}
```

A *projection* drops them, on purpose: `select(into:)` produces rows, not
models, and there is nothing to hang an association on.

## Accessing what you loaded

``Loadable`` is a small enum: loaded, or not.

```swift
for post in posts {
    let author = try post.author.get()          // throws if not preloaded
}
```

``Loadable/isLoaded`` asks without throwing, when the answer is genuinely
optional, and ``Loadable/optional`` hands back `nil` instead of throwing.

Encoding is provided: a loaded association encodes as its value, an unloaded
one as `null`, so a preloaded model can be serialized without a hand-written
mirror type. There is deliberately no matching `Decodable` — on the wire
`null` cannot separate "not fetched" from "fetched, and there is genuinely
nothing there", and a decoder would have to guess. Models go *out* of an
application as JSON; what comes back *in* is a request type of its own.

## Why it throws

An unloaded association could have returned an empty array. It does not,
deliberately.

An empty array is indistinguishable from "this post genuinely has no
comments", so the mistake would surface as a page that renders correctly and
silently omits data — the hardest kind of bug to notice. Throwing turns a
forgotten `.preload` into an immediate, obvious failure with the association
named.

## Nested preloads

An association's own associations load too, and the inner query can be tuned:

```swift
Post.all.preload(\.comments) { comments in
    comments.where { $0.approved == true }.order { $0.createdAt.asc() }
}
```

## Optional relationships

A foreign key that may be NULL is an ordinary relationship, on both sides.

On the child side, a nullable key pairs with an optional `Loadable`, and
`.loaded(nil)` is a real answer — "preloaded, and there is genuinely nothing
there" — distinct from `.notLoaded`:

```swift
@Column("authorID") var authorID: UUID?

@BelongsTo(foreignKey: \Message.authorID)
var author: Loadable<User?>
```

On the parent side, nothing changes at the declaration:

```swift
@HasMany(foreignKey: \Message.authorID)
var authored: Loadable<[Message]>
```

The keypath's type is what selects the loader, so `@HasMany` over a nullable
key needs no different spelling. Children whose key is NULL belong to no
parent and appear under none; the query still binds only non-null parent
keys, so `= ANY($1)` never has to reason about NULL.

The same asymmetry shows up in join conditions, where a nullable column can
be compared against a non-null one directly:

```swift
Message.leftJoin(User.self, on: { message, user in message.authorID == user.id })
```

Swift will not unify `Column<UUID?>` with `Column<UUID>` on its own, so
Hangar supplies the mixed comparison. SQL draws no such distinction: `=`
against NULL yields NULL, which a `JOIN` or `WHERE` reads as "no match" —
exactly what an optional relationship means. A `leftJoin` then keeps the
unmatched rows, which is usually the point; an inner join here would drop
them silently.

## Many-to-many, through a join table

`@HasMany(through:)` declares the two-hop shape; loading is two batched
queries — join table, then related table — reassembled in memory:

```swift
@HasMany(through: PostTag.self, from: \PostTag.postID, to: \PostTag.tagID)
var tags: Loadable<[Tag]>
```

`from:` references this entity's key on the join table; `to:` references
the related entity's; the related key follows the `\Related.id` convention.
At the call site `.preload(\.tags)` is identical to a direct has-many.
Duplicate join rows yield duplicate children — the data's truth — and a
join row referencing a vanished child is skipped.
