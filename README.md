# hangar

A type-safe query layer for PostgreSQL, built directly on
[PostgresNIO](https://github.com/vapor/postgres-nio).

Models are structs. Queries are values you compose. Columns are keypaths, so a
typo is a compile error rather than a runtime one.

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

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Alula-Framework/hangar", from: "0.8.1")
]
```

Requires Swift 6.2+. Linux and macOS 15+.

## Queries are values

Nothing executes until a `Repo` runs it, so a query can be built in pieces,
passed around, stored, and reused:

```swift
let base = Post.where { $0.published == true }

let recent = base.order { $0.createdAt.desc() }.limit(10)
let byAuthor = base.where { $0.authorID == id }      // `base` is unchanged
```

Composition never mutates what it was composed from. Because `where` is an
ordinary `(Query) -> Query` function, it folds over a collection like any
other value — a `reduce` over filter cases works as well as an `if let`
chain:

```swift
enum PostFilter { case published, author(UUID), search(String) }

let filters: [PostFilter] = [.published, .author(currentUserID)]

let q = filters.reduce(Post.all) { q, filter in
    switch filter {
    case .published:        q.where { $0.published }
    case .author(let id):   q.where { $0.authorID == id }
    case .search(let term): q.where { $0.title.ilike("%\(term)%") }
    }
}
```

## What it does

**Predicates** with real operators — `==`, `<`, `&&`, `||`, `!`, `in`,
`like`, `ilike`:

```swift
Post.where { $0.published == true && $0.viewCount > 100 }
Post.where { $0.title.ilike("%swift%") }
Post.where { $0.authorID.in(activeAuthorIDs) }
```

**Aggregates and projections** into any `Decodable`:

```swift
struct AuthorStats: Decodable {
    let authorID: UUID
    let posts: Int
    let views: Int
}

try await repo.all(
    Post.groupBy { $0.authorID }
        .having { $0.viewCount.sum() > 1_000 }
        .select(into: AuthorStats.self) { p in
            (p.authorID, p.id.count(), p.viewCount.sum())
        }
)
```

**Correlated scalar subqueries** — another query as one column of this one:

```swift
Post.select(into: PostWithCount.self) { post in
    (title: post.title,
     comments: Comment.where { $0.postID == post.id }.scalarCount(),
     author: Author.where { $0.id == post.authorID }.scalar { $0.name })
}
```

The inner `where` may reference the outer row, like `exists()`. `scalarCount()`
is non-optional (`count(*)` over no rows is 0); `scalar` is optional and takes
`LIMIT 1`, because a subquery matching no row is NULL and one matching two is a
runtime error.

**Set operations** — `union`, `unionAll`, `intersect`, `except` between two
queries over the same entity:

```swift
let urgent = Post.where { $0.viewCount > 10_000 }
let recent = Post.where { $0.createdAt > cutoff }

try await repo.all(
    urgent.union(recent)
        .where { $0.published }       // filters the combined set
        .order { $0.createdAt.desc() }
        .limit(20))
```

The combination is read as a derived table, so the result is an ordinary query
again: everything downstream — `where`, `order`, `limit`, `count`, preloads —
applies to the combined rows. Each branch keeps its own `ORDER BY` and `LIMIT`,
so "the twenty most viewed, plus the five newest" is two bounded branches.
Whole rows only: both sides select one entity's columns, which is what
guarantees the shapes match.

**Window functions** — a value computed from the rows *around* this one.
Every aggregate gains `.over`, so the same call site answers two questions:

```swift
struct Ranked: Decodable {
    let title: String
    let position: Int
    let authorTotal: Int?
}

try await repo.all(
    Post.select(into: Ranked.self) { p in
        (title: p.title,
         position: rowNumber().over(
             .partition(by: p.authorID).order(by: p.viewCount.desc())),
         authorTotal: p.viewCount.sum().over(.partition(by: p.authorID)))
    })
```

The call site is meant to read as the SQL it becomes —
`rank().over(.partition(by:).order(by:))` against
`rank() OVER (PARTITION BY … ORDER BY …)`.

`rowNumber()`, `rank()`, `denseRank()`, and `lag`/`lead` on any column. Those
have no meaning outside a window, so they return a value whose only method is
`.over` — the invalid form is unspellable rather than a runtime error. An empty
`.over()` is the whole result set, which is how `count().over()` puts the total
beside each row.

Frames say which rows around this one the function reads, which is what a
trailing average needs — without one the window is the whole partition:

```swift
// This row and the two before it, in date order.
p.viewCount.avg().over(.order(by: p.createdAt.asc()).rows(from: .preceding(2)))
```

`rows` counts physical rows and `range` counts peers (rows the ordering cannot
tell apart). Start and end are separate types, so a frame starting at
`UNBOUNDED FOLLOWING` — or ending at `UNBOUNDED PRECEDING` — does not compile.

**Joins**, inner and left, with the base entity's columns qualified —
including self-joins through table aliases:

```swift
Post.leftJoin(Comment.self, on: { post, comment in comment.postID == post.id })
    .groupBy { post, _ in post.id }

Employee.alias("manager").join(Employee.alias("report"),
    on: { manager, report in report.managerID == manager.id })
```

An unaliased self-join is refused with the remedy named — every column
reference would be ambiguous — and composition closures after an aliased
join see alias-qualified columns throughout.

A third table joins on from any two-table join, the closure seeing all
three column sets:

```swift
Post.join(Comment.self, on: { p, c in c.postID == p.id })
    .join(Author.self, on: { _, comment, author in comment.authorID == author.id })
    .select(into: Row.self) { p, c, a in (title: p.title, commenter: a.name) }
```

**More than three tables — or self-joins, or too many positional blanks —
go through `Table.query { }`**, where each join hands back that table's
columns as an ordinary `let`:

```swift
let report = try await repo.all(
    Order.query { q, order in
        let customer = q.join(Customer.self) { $0.id == order.customerID }
        let item = q.join(OrderItem.self) { $0.orderID == order.id }
        let product = q.join(Product.self) { $0.id == item.productID }
        q.where(customer.active)
        return q.select(into: OrderReport.self) {
            (id: order.id, customer: customer.name, product: product.name)
        }
    })
```

Three things it buys over the fixed-arity forms: **any number of tables**
(the join list is erased, so the value stays `ComposedQuery<Base, Result>`
whether it joins two tables or seven); **names instead of positions** —
`{ _, comment, author in ... }` is already the ergonomic ceiling at three;
and **self-joins with no `.alias(_:)`**, since every join mints its own
alias and collision is impossible by construction. Everything else is the
same: `where`/`order`/`groupBy`/`having`/`limit`/`distinct`, `select` and
`select(into:)`, `repo.all`/`one`/`count`/`exists`, preloads on the
base-entity path, and the same soft-delete scope.

`q.query()` and `q.select` snapshot the builder, so a mutation after one of
them would change nothing — Hangar traps rather than ignoring it.
`JoinedQuery`/`JoinedQuery3` remain, and their closure form stays the nicer
spelling for a quick two-table join; the arity is frozen there, and this is
the answer above it.

**`DISTINCT ON`** for one-row-per-group reads, with the same last-call-wins
relationship to `.distinct()` that repeated `.limit` calls have:

```swift
// The newest post per author:
Post.distinct(on: { $0.authorID })
    .order { $0.authorID.asc() }
    .order { $0.createdAt.desc() }
```

**Preloading** that batches rather than N+1 — one query per association, using
`= ANY($1)`:

```swift
try await repo.all(Post.all.preload(\.author).preload(\.comments))
```

Many-to-many goes through a join table, loaded the same batched way — two
queries, never a SQL join:

```swift
@HasMany(through: PostTag.self, from: \PostTag.postID, to: \PostTag.tagID)
var tags: Loadable<[Tag]>
```

A nullable foreign key is an ordinary relationship: `@HasMany` over one needs
no different spelling (children whose key is NULL belong to no parent), and
the child side pairs it with an optional `Loadable`, where `.loaded(nil)`
means "preloaded, and there is genuinely no author" — a different fact from
`.notLoaded`.

An association that was never preloaded throws `notPreloaded` rather than
silently returning nothing. Loud beats empty. A preloaded model encodes to
JSON as-is (unloaded associations become `null`); there is deliberately no
`Decodable`, since `null` on the wire cannot separate "not fetched" from
"fetched, and empty".

**Transactions** with real savepoint nesting, isolation levels, and
retry-on-serialization-failure:

```swift
try await repo.transaction(isolation: .serializable, retryingOnSerializationFailure: 3) { tx in
    try await tx.insert(order)
    try await tx.transaction { inner in       // SAVEPOINT
        try await inner.insert(lineItem)
    }
}
```

**`Multi`** for units of work whose steps are decided before they run — the
shape to reach for when a `transaction { }` closure would become a tangle of
conditionals:

```swift
enum K {
    static let user = MultiKey<User>("user")
    static let profile = MultiKey<Profile>("profile")
}

var multi = Multi()
    .insert(K.user, userChangeset)
    .insert(K.profile) { results in            // reads the row just inserted
        profileChangeset(for: try results[K.user])
    }
if sendWelcome {
    multi = multi.run(MultiKey<Void>("email")) { results in
        try await mailer.welcome(try results[K.user])
    }
}

switch try await repo.run(multi) {
case .success(let values):
    let user = try values[K.user]
case .failure(let failure):
    // failure.key names the step, failure.error is what it threw, and
    // failure.completed holds the results from before it — all rolled back.
    logger.error("step \(failure.key) failed: \(failure.error)")
}
```

Three things make it worth the indirection over a plain transaction:

- **Steps are values.** Build one conditionally, return it from a function,
  compose two with `merging(_:)`. Nothing runs until `repo.run(multi)`.
- **Later steps read earlier results** through typed keys — `results[K.user]`
  is a `User`, not a dictionary lookup you have to cast.
- **A failed step is a value, not a thrown error.** `MultiResult.failure`
  names the step that failed and carries what completed before it, so the
  handler can say which unit of work broke instead of unwrapping an error and
  guessing. The throw path stays reserved for the transaction machinery
  itself.

Everything runs in one transaction, so any failure rolls all of it back.

**`EXPLAIN`** for the other half of a slow query. The diagnostics below say
which statement is slow; this says why:

```swift
let plan = try await repo.explain(
    Post.where { $0.authorID == id }.order { $0.createdAt.desc() },
    mode: .analyze)
```

`.plan` estimates without running; `.analyze` runs and reports what actually
happened, which is usually the answer — the estimate and the reality
diverging is the diagnosis. Returned as the text `psql` shows, deliberately
unparsed: a plan is something a human reads, and a structured form would be
another thing to keep in step with Postgres across versions.

**Slow-query and N+1 reporting.** Every statement is timed into
`hangar.query.duration` regardless, but a timer cannot say which query is
slow. Opt in and it will:

```swift
var repo = Repo(client: pool, logger: logger)
repo.diagnostics = .recommended     // 200ms, and 20 repeats in one unit of work

try await repo.detectingRepeatedQueries {
    try await renderDashboard()     // warns if one statement shape repeats
}
```

Both are off by default: a threshold that fires on everything is noise, and
one that never fires is a setting nobody tuned.

**Pagination** with the count behind it:

```swift
let page = try await repo.page(
    Post.where { $0.published }.order { $0.createdAt.desc() },
    PageRequest(page: 2, perPage: 20))

page.items          // the slice
page.total          // matching rows, ignoring limit and offset
page.pageCount      // and so hasNext, isLast, "showing 21–40 of 137"
```

`PageRequest` clamps on construction *and when decoded*, because a page size
usually arrives from a query string and `?perPage=100000` should be a large
page rather than a way to ask for the whole table. Its offset saturates
instead of overflowing, so `?page=9223372036854775807` is an empty page, not
a crashed process. A query with no `ORDER BY` is paginated by
primary key — `LIMIT`/`OFFSET` without an order lets Postgres return a row on
two pages or none.

**Soft deletion**, opt-in per entity:

```swift
@Entity("files")
struct StoredFile {
    @ID let id: UUID
    @Deleted @Column("deleted_at") var deletedAt: Date?
}
```

Reads exclude deleted rows, `repo.delete(model)` stamps the column instead of
issuing a `DELETE`, and `repo.restore` brings a row back. The *exclusion* is
applied to the query rather than to each statement kind, so `select`, `count`,
`exists`, set-based `update` and `delete`, and preloaded associations all
inherit it.

The *stamping* is not: `repo.delete(query)` — the set-based overload — issues a
real `DELETE` even for a soft-deletable entity. That is deliberate and the
retention purge below depends on it, since a scheduled job clearing rows past a
cutoff has nothing left to stamp. But it means one method name does two
different things depending on whether you hand it a model or a query, so reach
for the set-based form only when you mean it. The escape hatches are named: `withDeleted()`, `onlyDeleted()`,
`forceDelete()` — spelled either on a query (`StoredFile.all.onlyDeleted()`)
or straight on the entity (`StoredFile.onlyDeleted()`).

**Joins carry the scope too**, in all three forms — two-table, three-table,
and `Table.query { }`. The rule is one sentence: the base entity is scoped
in `WHERE`, every soft-deletable *joined* table excludes its own deleted
rows in its `ON` clause, and `withDeleted()` lifts both.

```swift
// The trash view, joined to live owners — not to deleted ones:
StoredFile.onlyDeleted().join(Author.self, on: { file, owner in owner.id == file.ownerID })

// Every author, including one whose only file is deleted: the child's
// scope is in ON, so the outer join stays outer.
Author.leftJoin(StoredFile.self, on: { owner, file in file.ownerID == owner.id })
```

`ON` rather than `WHERE` for the joined side is the whole reason a `LEFT
JOIN` keeps its unmatched rows; for an inner join the two are equivalent,
so one rule covers both. `.only` scopes the base alone — a trash view of
files still joins to live owners — while `withDeleted()` says "stop
filtering on deletion in this query" and so lifts it everywhere.

A nullable column supports the same ordering comparisons a non-nullable one
does — `<`, `>`, `<=`, `>=` — which is what makes "purge everything past its
retention window" an ordinary query against `@Deleted`'s own column, or any
other nullable timestamp:

```swift
try await repo.delete(StoredFile.onlyDeleted().where { $0.deletedAt < cutoff })
```

The right-hand side is never optional: `deletedAt < nil` has no SQL meaning,
and keeping `nil` out of these overloads is what keeps `== nil` rendering
`IS NULL` rather than being captured by one of them.

**Row locks and raw statements** where the type system can't reach —
`lockForUpdate()` is first-class, and `execute` is bind-safe raw SQL on the
transaction's own connection:

```swift
try await repo.transaction { tx in
    try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
    let account = try await tx.one(Account.where { $0.id == id }.lockForUpdate())
    ...
}
```

**Streaming** for result sets that should not be materialized:

```swift
try await repo.stream(Post.all.order { $0.id.asc() }) { posts in
    for try await post in posts { … }
}
```

**Bulk writes** — one statement across every row a predicate matches, with
the count returned and typed, bound assignments:

```swift
try await repo.insert(rows.map(Event.init))          // one multi-row INSERT
try await repo.delete(Session.where { $0.expiresAt < .now })
try await repo.update(Post.where { $0.published == false }) {
    ($0.published.set(to: true), $0.reviewedAt.set(to: Date()))
}
```

A query carrying a clause the statement cannot honor — `limit`, `order`,
`groupBy` — throws rather than executing with it silently dropped.

**Changesets**, upserts, dynamic filters over an explicit allowlist, array
columns (`text[]`, `integer[]`, ...), and read-replica routing.

## Queries Postgres would reject do not compile

Four mistakes that used to reach the server and fail there are build errors
now, each naming the rule it breaks and the fix:

```swift
Post.where { $0.viewCount.sum() > 5 }
// error: 'where' is unavailable: Aggregate functions are not allowed in WHERE
// — Postgres rejects this. WHERE chooses the rows that feed the aggregate, so
// it cannot also read it. Group the rows and use HAVING instead:
// `.groupBy { $0.someColumn }.having { ... }`.

try await repo.all(Post.groupBy { $0.authorID })
// error: 'all' is unavailable: A grouped query has no whole rows to fetch —
// GROUP BY collapses them, and Postgres answers "column ... must appear in the
// GROUP BY clause or be used in an aggregate function". Choose the columns
// instead: `.select(into: Summary.self) { ($0.someColumn, $0.other.count()) }`,
// or ask about the groups with `count` / `exists`.

Post.all.groupBy { $0.authorID }.having { $0.viewCount.sum().over() > 5 }
// error: '>' is unavailable: Window functions are not allowed in WHERE or
// HAVING — Postgres rejects this. A window is computed after those clauses
// have already chosen the rows, so it cannot decide which rows they choose.
// Select it here, put this query in a CTE with `.with(...)`, and compare the
// column in the outer query.
```

An aggregate comparison is an `AggregatePredicate` and a windowed one is a
`WindowExpression`; `where` accepts neither, and `having` accepts the first.
The types are the enforcement, and the unavailable overloads exist so the
compiler explains rather than saying "binary operator cannot be applied".

`CI/check-invalid-queries-fail.sh` compiles a package of these queries on every
push and fails if any of them builds — a compile-time guarantee is exactly the
kind of claim that rots silently when an overload is widened.

## Safety

Identifiers are always quoted with embedded quotes doubled. Values are always
bound, never interpolated. Dynamic filter fields resolve through an allowlist
and are never interpolated. Savepoint names are generated from an integer
depth, never from user input.

`SQLFragment`'s `\(raw:)` is the one deliberate hole, and it announces itself.

Server errors arrive as a typed `DatabaseError` — `isUniqueViolation`,
`constraint`, `columnName` — whose description never quotes row values, and
failures are logged the same way. A transaction whose body swallowed a failed
statement throws `HangarError.transactionAborted` instead of reporting a
commit Postgres did not perform.

## Binding a repo to a connection you own

A `Repo` normally holds a pool. It can instead be pinned to a connection you
manage — which is how a framework binds one to a request scope:

```swift
let repo = Repo(connection: connection)
```

> **If that connection is already inside a transaction, say so.**
>
> ```swift
> Repo(connection: connection, inTransaction: true)
> ```
>
> At the default, the repo believes it is outermost and `transaction { }`
> emits a literal `BEGIN`/`COMMIT`. Postgres ignores the redundant `BEGIN`,
> and the `COMMIT` then ends *your* transaction — so work you meant to roll
> back becomes durable. With `inTransaction: true` it nests as a savepoint.
>
> Hangar cannot detect this itself: PostgresNIO does not expose the
> connection's transaction status. The caller knows, so the caller says.

## Starting from a database you already have

`HangarIntrospection` reads a live schema and writes `@Entity` types for it,
so adopting Hangar on an existing database is not a transcription exercise:

```swift
import HangarIntrospection

let introspector = SchemaIntrospector(client: client)
for (typeName, source) in try await introspector.generateEntities() {
    try source.write(to: directory.appending(path: "\(typeName).swift"),
                     atomically: true, encoding: .utf8)
}
```

It reads `pg_catalog` rather than `information_schema` — the standard views
cannot tell an array's element type, name an enum's labels, or distinguish
identity from default without extra joins, and there is nothing to gain from
portability in a Postgres-only tool.

What it decides, and what it refuses to:

- Primary keys become `@ID`, and `@ID(generated: true)` when the database
  supplies the value.
- Nullable columns become optionals; `snake_case` becomes `camelCase` with
  `@Column` carrying the mapping.
- Postgres enums become Swift enums with their labels in declaration order.
- A nullable, conventionally-named `deleted_at` becomes `@Deleted`.
- A type with no faithful Swift counterpart becomes a `TODO` naming it,
  never a guess — a wrong type here is a runtime decode failure in code
  nobody wrote by hand and nobody thinks to doubt. `jsonb` compiles as
  `String` with a comment pointing at `@JSONB`.
- Foreign keys are **reported as comments**, not turned into associations.
  The property name, the direction, and whether the other side wants a
  has-many are decisions the generator cannot make for you.

The output is meant to be read, edited, and committed — a starting point,
not a build artifact.

## Common table expressions

A CTE is a value. Build it where it makes sense, pass it where it is needed:

```swift
let popular = CommonTable<Post>("popular")
    .where { $0.viewCount > 1_000 }
    .order { $0.viewCount.desc() }
    .limit(50)

try await repo.all(
    Post.all
        .with(popular)
        .where { $0.authorID.in(popular.select { $0.authorID }) })
```

The name is written once and travels with the body, so a declaration and a
reference cannot disagree — the older spelling took it twice, in
`with("popular", as:)` and again in `reading(from: "popular")`, and a
misspelling was a runtime error about a relation that does not exist.
`popular.all` reads it back as whole `Post` rows; `popular.select { … }` takes
one column out of it for a membership test. Declaring the same CTE twice
declares it once, because a `WITH` list that names it twice is an error rather
than a query.

A recursive CTE is the same value, defined in terms of itself:

```swift
let tree = CommonTable<Node>("tree")

try await repo.all(
    Node.all
        .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
            Node.join(found, on: { child, parent in child.parentID == parent.id })
        }
        .reading(from: tree))
```

The step receives the CTE being defined and joins it — `JOIN "tree"`, not the
entity's table — which is the only way to write one, since it refers to itself.
The step used to have to be raw SQL for exactly that reason: no entity
describes a relation that does not exist yet.

**Over a graph rather than a tree, ask for cycle detection:**

```swift
let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })
```

Without it Postgres walks a cycle until the connection dies. With it,
recursion stops at the row that closes the cycle, and that row — a duplicate
of one already returned — is dropped when you read the CTE back; pass
`includingCycleClosers: true` to `reading(from:)` to see it. Requires Postgres
14 or later.

Whether you need this is not something a signature can tell you: a cycle is a
property of the data, not of the query, and the same walk is finite over a
tree and endless over a graph. What the type can do is make asking for it one
call.

A CTE body is a whole-row query by construction. That is the guarantee that
makes reading it back as the entity safe: a projection would not expose the
entity's columns, so narrowing belongs on the reference side, not the body.

## What is not here

No migrations — use a migration tool.

## Documentation

```bash
HANGAR_BUILD_DOCS=1 swift package generate-documentation --target Hangar
```

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md), including the measured cost of unnamed vs
named prepared statements and where preloading stops scaling.

## Running the tests

```bash
./scripts/test.sh                 # everything, integration tests included
./scripts/test.sh --filter Foo    # arguments pass through to swift test
```

It starts throwaway servers, runs the suite, and removes them. The
integration suites skip without a database, and a skipped suite is not a
passing one — what this package proves against real infrastructure is most of
what it is for.

`ALULA_KEEP_SERVERS=1` leaves the containers up between runs.

## License

MIT. See [LICENSE](LICENSE).
