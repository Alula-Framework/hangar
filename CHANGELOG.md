# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.2] - 2026-09-25

### Changed

- **An error about the statement itself says what is wrong.** A syntax error
  or an undefined column, function or table (SQLSTATE class 42), or a
  feature not supported (0A), described itself as `database error (SQLSTATE
  42703)` — not which column (Relay #17). For those classes the server's
  message is now part of `DatabaseError.description` and of the failure log:
  `database error (SQLSTATE 42703): column "nmae" does not exist`. It names
  only what the statement names, and the statement is already in the log.
  Every other class stays metadata only.

## [0.11.1] - 2026-09-25

### Changed

- **A failed statement is logged at the level its meaning deserves.** Every
  failure was `error`, the level an operator pages on, so a taken email the
  application answered with a 409 looked like an incident (Relay #35). A
  constraint violation (SQLSTATE class 23) is now `info` — the caller
  decides whether it is an error — and a serialization failure or deadlock
  is `notice`, since running it again is the remedy. Everything else stays
  `error`. The line's content is unchanged: metadata only, never values.

## [0.11.0] - 2026-09-25

### Changed

- **A row lock on a set operation throws instead of stopping the process.**
  Locking a branch and then combining it with `union`, `intersect` or `except`
  was a `precondition` — a crash of the whole server on the request that built
  the query. Locking the combination itself was not caught at all, and failed
  at Postgres. Both now throw `HangarError.rowLockOnSetOperation`
  (`HGR-QUERY-4005`, with a page) when the query runs, before anything is sent.
  `HangarError` gains that case, so an exhaustive `switch` over it needs one
  more.
- **A negative window-frame offset fails the request, not the process.** It
  was a precondition, on the reasoning that the offset is a literal at the
  call; "the last N rows" takes N from a request. Postgres's own error now
  reaches the caller as a `DatabaseError`.

## [0.10.2] - 2026-09-25

### Changed

- **Query compile errors carry codes and pages.** The four mistakes Hangar
  turns into build errors — an aggregate in WHERE, a window function in a
  filter, a frame bound pointing the wrong way, fetching a grouped query as
  whole rows — now read `[HGR-QUERY-4001]` to `[HGR-QUERY-4004]` and end with
  a link to their page in `Diagnostics/`. The codes are stable; search for
  them. `CI/check-invalid-queries-fail.sh` fails if a declared code is never
  produced or has no page.

### Fixed

- The grouped-fetch message printed long runs of spaces mid-sentence: its
  source lines had been joined rather than wrapped.

## [0.10.1] - 2026-09-25

An external audit of 0.10.0 found three problems; each is fixed and pinned
by tests.

### Fixed

- **Chunking no longer changes what a bulk `DO UPDATE` means.** In one
  statement, two rows sharing a conflict key make Postgres refuse the upsert
  (SQLSTATE 21000); split across statements — which 0.10.0 does past the
  bind-parameter limit — each chunk updated the row and the batch
  succeeded. The same input now gets the same answer at any size: repeated
  keys are refused before anything is sent, and a split `DO UPDATE` whose
  keys cannot be checked (a constraint-named target, a non-`Hashable` key)
  is refused rather than split on faith. A differential property runs every
  generated batch whole and force-split and requires identical results.
- **`DatabaseError`'s description and the failure log are metadata only.**
  0.10.0 dropped the server's detail but kept its primary message, which
  can quote data too — `invalid input syntax for type integer: "…"`, or
  anything a trigger `RAISE`s. The description is now kind, SQLSTATE,
  table, constraint and column names; `message` and `underlying` keep the
  server's words for code that wants them. The log also drops the hint.
- **`Page.pageCount` uses integer arithmetic**; it went through `Double`,
  which stops representing every integer at 2^53.

### Documentation

- `repo.insert(models)` is documented as usually one statement, split into
  several inside one transaction past the bind limit — which matters for
  statement-level triggers. The README no longer claims `scalar` adds
  `LIMIT 1` (it deliberately does not; `scalarFirst` does).

### Added

- **`TransactionObserver`** — `Repo(connection:…, transactionObserver:)` is
  told when the repo opens and closes its outermost transaction on the
  pinned connection (`began` before `BEGIN`, `ended` once `COMMIT` or
  `ROLLBACK` has been answered, exactly once). It is the seam a pool needs
  to never hand the next borrower a connection with a transaction still
  open, without Hangar knowing anything about the pool; alula-data 0.17.0
  uses it. A property test checks one began/ended pair for every generated
  transaction body, failing or not.
- `DatabaseError.kindName`.

## [0.10.0] - 2026-09-24

A Postgres audit of Hangar against the bugs, pull requests and tests of
Fluent, SQLKit/PostgresKit, PostgresNIO and the other Swift Postgres
libraries. Every finding below was reproduced against Postgres 16 before it
was fixed, and each fix ships with regression tests and, where the behavior
has a shape, property or adversarial tests against the server.

### Fixed

- **A transaction no longer reports a commit that did not happen.** After any
  statement fails, Postgres aborts the transaction and answers the final
  `COMMIT` with `ROLLBACK` — no error. A body that caught the failure and
  carried on therefore got a normal return with none of its work saved.
  `transaction { }` now checks what `COMMIT` did and throws
  `HangarError.transactionAborted(cause:)`, naming the statement that failed
  first. A savepoint whose `RELEASE` is refused, and a statement run after
  the failure (SQLSTATE 25P02), report the same error instead of a bare
  25P02. Verified against Postgres; PostgresNIO's `withTransaction` and
  Fluent have the same flaw.
- **A request can no longer crash the process through pagination.**
  `PageRequest.offset` multiplied without overflow checking, so
  `?page=9223372036854775807` trapped. It saturates now, as do
  `Page.firstIndex`/`lastIndex`. Decoding a `PageRequest` also clamps — the
  synthesized decoder skipped it, letting `page=-5` through as a negative
  `OFFSET` and `perPage=100000` as a hundred-thousand-row page — and missing
  fields take their defaults.
- **Batch inserts past 65,535 values work.** A multi-row insert binds
  rows × columns parameters, and Postgres's protocol caps a statement at
  65,535; `repo.insert(models)` failed with PostgresNIO's
  `tooManyParameters` (printing the entire statement). It now inserts in
  chunks that fit, inside a transaction — a savepoint when nested — so the
  batch stays all-or-nothing and the rows still come back in input order.
- **An entity whose every column is database-generated can be inserted.**
  It rendered `INSERT INTO t () VALUES ()`; it renders `DEFAULT VALUES`
  (or `VALUES (DEFAULT), …` in bulk).
- **A cancelled transaction no longer commits.** PostgresNIO does not stop
  a running statement, so a body could finish after its task was cancelled
  — typically when the request it served went away — and its `COMMIT` made
  the abandoned work durable. The outermost level now checks for
  cancellation before committing and rolls back with `CancellationError`.
  Found by the new cancellation test.
- **Failure logs no longer contain row data.** The error-level "statement
  failed" line included the server's `DETAIL`, which for unique and
  foreign-key violations quotes the row (`Key (email)=(ada@…)`). It now
  carries the SQLSTATE, message, table, constraint and column *names* only.

### Added

- **`DatabaseError`: server errors, typed.** Every server-side failure a
  `Repo` sees arrives as `DatabaseError` with a `kind` (`.uniqueViolation`,
  `.foreignKeyViolation`, `.checkViolation`, `.notNullViolation`,
  `.serializationFailure`, `.deadlock`, `.lockNotAvailable`, …), the
  SQLSTATE, table, constraint, and the column names — for unique and
  foreign-key violations read from the key list in the server detail, values
  discarded. `description` is safe to log; the full `PSQLError` is
  `underlying`. This is the type swift-changeset's documentation already
  showed (`catch let error as DatabaseError where error.isUniqueViolation`),
  which did not exist.
- `PageRequest.clamped(maximumPerPage:)` and `PageRequest.defaultMaximumPerPage`.
- **`contains`, `hasPrefix`, `hasSuffix`** (with `caseInsensitive:`) on text
  columns match a term literally: `%`, `_` and `\` in it are escaped, so a
  search for `50%` no longer finds `500` and a lone `%` no longer matches
  every row. `likeEscaped(_:)` does the escaping for hand-built patterns. The
  README's search example used `ilike("%\(term)%")` and now uses `contains`.
- **Upsert names conflicts every way Postgres does.** A constraint
  (`.doNothing(constraint:)`, `.doUpdate(constraint:set:)`), a partial
  unique index (`target:where:` — without the index predicate Postgres finds
  no arbiter and fails with 42P10), and a conditional `DO UPDATE`
  (`updateWhere: { existing, incoming in existing.version < incoming.version }`,
  where `incoming` is `EXCLUDED`). **Bulk upsert:** `repo.insert(models,
  onConflict:)` returns the rows written, in input order, chunked like
  `insert(models)`.
- **Column-to-column `<`, `>`, `<=`, `>=`.**
- **`status.in([...])` on enum columns.** It did not compile: enums are not
  array-encodable, and `= ANY(text[])` is rejected against an enum. It
  renders `status IN ($1, $2)`, each label typed by the server from the
  column (so an index still applies); an empty list is `FALSE`.
- **`NullableArray<T>`** for arrays with NULL elements (`{1,NULL,3}`), which
  PostgresNIO refuses to decode — one NULL made the row unreadable.
- **`EnumArray<E>`** for arrays of a Postgres enum (`role[]`), which had no
  mapping at all. Labels are written quoted, so one spelled `NULL` or holding
  a comma, brace or quote cannot change the array's shape.
- **`SKIP LOCKED`, `NOWAIT`, `FOR NO KEY UPDATE`, `FOR KEY SHARE`.**
  `lockForUpdate(wait: .skipLocked)` is the job-queue claim;
  `lock(.noKeyUpdate)` locks a row for a non-key change without blocking
  inserts that reference it. `lockForUpdate()`/`lockForShare()` are
  unchanged.
- **Zone-free temporal types.** `CalendarDate` (`date`), `LocalDateTime`
  (`timestamp`), `LocalTime` (`time`) and `PostgresInterval` (`interval`)
  travel in each column's own wire format, so no time zone is consulted. A
  `Date` bound to a `date` or `timestamp` column goes through the session's
  time zone — a `date` written from Tokyo lands a day later than from UTC,
  and a `timestamp` read back is off by the session's offset.
  `hangar-introspect` now maps `date`, `timestamp`, `time` and `interval` to
  them (it mapped the first two to `Date` and skipped the others), `date[]`
  to `[CalendarDate]`, and enum arrays to `EnumArray`, declaring each enum
  once.
- **Tables in another schema: `@Entity("invoices", schema: "billing")`.**
  `@Entity("billing.invoices")` quoted the whole string as one identifier —
  a legal, different table — so a table outside the `search_path` could not
  be mapped. Statements now read and write `"billing"."invoices"`, while
  columns qualify by the bare table name, as Postgres resolves them.
  `hangar-introspect` passes the schema for tables outside `public`.
- **`transaction(statementTimeout:)`**: a server-enforced bound on every
  statement in the transaction (`SET LOCAL statement_timeout`), failing with
  `DatabaseError.Kind.queryCanceled`. The only way to bound a query:
  cancelling the task does not stop it.
- **`sum`/`avg` on `numeric` columns** (exact, as `Decimal`) **and on nullable
  columns**, which had none. `DatabaseError.Kind.numericValueOutOfRange`
  (22003) names the error an integer sum past `bigint` raises.
- **`isDistinct(from:)` / `isNotDistinct(from:)`** on optional columns render
  `IS [NOT] DISTINCT FROM` — Swift's answer for NULL. `!=` keeps SQL's
  (NULL rows are not returned, consistent with `!(==)`), now documented.

### Changed

- **`ON CONFLICT` clauses Postgres would reject are refused before
  sending**: a `DO UPDATE` with no target (which sql-kit still renders) or
  nothing to set, and an empty constraint name, throw
  `HangarError.invalidConflictClause`.
- **Breaking: server errors are `DatabaseError`, not `PSQLError`.** Code that
  caught `PSQLError` and read `serverInfo[.sqlState]` should catch
  `DatabaseError` and read `kind` or `sqlState`. Errors that never reached
  the server (connection, decoding, client-side limits) are unchanged.
- **Breaking: `Repo.execute` returns `DatabaseRows`**, which iterates and
  `decode`s exactly like `PostgresRowSequence` and applies the same error
  handling to failures that arrive with the rows.
- **Breaking: `PageRequest.page` and `perPage` are read-only**, so the
  clamping cannot be assigned away.

## [0.9.2] - 2026-09-23

### Changed

- **The organization is now Alula-Framework**, after Flight was renamed
  Alula. The swift-changeset dependency uses its new URL, which removes the
  conflicting-identity warning for a package that depends on both Hangar and
  swift-changeset (alula-data does). GitHub redirects the old URLs, and the
  API is unchanged.

## [0.9.1] - 2026-09-19

### Fixed

- **Two declarations of the same CTE no longer trap.** 0.9.0 compared
  `CommonTable` values by object identity, so a factory returning
  `CommonTable<Post>("popular")` twice — the obvious way to share one — hit a
  precondition failure, even though both definitions were identical. It
  compares what they render to now: the same definition under one name is one
  declaration, and only genuinely different definitions conflict.

### Testing

- Five property tests written to break the library rather than to describe it.
  Every property this project had asked whether a *select* was built as
  intended; the two defects fixed in 0.8.1 were about what happened to a query
  afterwards, which is why none of them noticed.

  The new ones: Postgres parses everything the builder can produce (250
  generated programs, each PREPAREd against the server); a bulk write is
  refused or targets exactly what the query selects; no generated value reaches
  the SQL text of any statement kind; every WITH list names each CTE once; and
  rendering is deterministic.

  Verified by reintroducing the 0.8.1 defect, which the bulk-write property
  fails on and shrinks to a single step.

## [0.9.0] - 2026-09-19

The rest of the 0.7.0/0.8.0 audit. One behaviour change worth reading before
upgrading: `scalar` no longer adds `LIMIT 1`.

### Changed

- **`scalar` keeps the cardinality error.** It used to impose `LIMIT 1`, which
  turned "the author's name" into "an author's name" — a missing uniqueness
  assumption kept working until two rows matched. Postgres answers a subquery
  returning two rows with "more than one row returned by a subquery used as an
  expression", and that error is the assumption announcing itself.
  ``scalarFirst`` is the explicit opt-in when several matches are expected and
  any one will do.

### Fixed

- **A combination no longer re-applies the entity's soft-delete scope.** Each
  branch already chose its rows, so filtering again outside was double
  filtering: `onlyDeleted().union(onlyDeleted())` selected `deleted_at IS NOT
  NULL` in both branches and then asked for `IS NULL`, which is empty, and
  `withDeleted().union(…)` quietly excluded what it had just asked for.
  Scoping the combination itself still works and now means what it reads as.

- **Two different CTEs under one name are refused.** Declaring the same value
  twice is one declaration, as before. Two different definitions sharing a
  name used to keep the first silently, leaving a query that referred to
  `popular` while containing `recent` — valid SQL, wrong answer. A `CommonTable`
  carries an identity now, and a conflict fails at the call.

- **A recursive step that cannot render says so.** The failure was swallowed
  into an empty string, so `anchor UNION ALL ` reached Postgres and the error
  came back as a syntax complaint about the wrong thing. The reason travels
  into the statement now.

- **A row lock cannot be combined.** Postgres refuses `FOR UPDATE` on a set
  operation and on its branches; `a.lockForUpdate().union(b)` was spellable
  and failed at the server.

- **A negative frame offset is refused at the call**, where the literal was
  written, rather than by Postgres on the request that runs it.

### Documentation

- The README's install snippet pointed at 0.6.0.
- `Window.swift`'s header said a window in `WHERE`/`HAVING` reaches the server
  rather than the compiler. That stopped being true in 0.7.0.

## [0.8.1] - 2026-09-19

Two data-correctness fixes in set operations. **Anyone on 0.7.0 or 0.8.0 using
`union`/`intersect`/`except` should upgrade.** Found by an external audit, not
by this project's own tests.

### Fixed

- **A bulk delete or update over a set operation targeted the whole table.**
  A combination is carried on the query's derived source, and the bulk-write
  validator did not reject it — so the derived source was dropped and

      repo.delete(Post.where { $0.flagged }.union(Post.where { $0.expired }))

  rendered `DELETE FROM "hangar_posts" RETURNING "id"`. No WHERE clause at
  all: every row in the table, from a call that reads as "delete the union of
  these two". It is refused now, named as a set operation, alongside the other
  clauses a bulk write cannot express.

- **Projecting or grouping a combination silently dropped it.** The retype
  paths copied thirteen fields and not the derived source, so

      combined.select { $0.title }

  rendered `SELECT "title" FROM "hangar_posts"` — the whole table, no error,
  because the result is still valid SQL over the entity. Both paths carry it
  now.

### Testing

- A test that every field of a query survives a retype, by reflection rather
  than by listing them. Both bugs above were one field missing from one
  copier, and this project has made that mistake before (`deletedRows`), so
  the check is structural rather than another enumeration to keep in sync.
  Verified by reintroducing the bug and watching it name the field.

## [0.8.0] - 2026-09-19

Common table expressions as values. Additive: nothing public was removed or
re-signed, and the string-based spelling still works.

### Added

- **A CTE is a value you build once.** The name and the body travel together,
  so a declaration and a reference cannot disagree:

      let popular = CommonTable<Post>("popular")
          .where { $0.viewCount > 1_000 }
          .order { $0.viewCount.desc() }
          .limit(50)

      Post.all
          .with(popular)
          .where { $0.authorID.in(popular.select { $0.authorID }) }

  The old spelling took the name twice — `with("popular", as:)` and then
  `reading(from: "popular")` — with nothing checking they matched, so a
  misspelling was a runtime error about a relation that does not exist.
  `popular.all` reads whole rows back, `popular.select { … }` takes one column
  out, and `reading(from: popular)` is typed too. Declaring the same CTE twice
  declares it once.

  A CTE body is a whole-row query by construction, which is the guarantee that
  makes reading it back as the entity safe: a projection would not expose the
  entity's columns, so column-narrowing lives on the reference side.

- **A recursive CTE's step is typed.** It used to have to be raw SQL, for a
  real reason — the step refers to the CTE being defined, and no entity
  describes a relation that does not exist yet. The handle is what changed
  that:

      Node.all
          .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
              Node.join(found, on: { child, parent in child.parentID == parent.id })
          }
          .reading(from: tree)

  A join may now name a CTE as its source — rendered bare, since a CTE is
  already a name — and that name satisfies the two-distinct-names guard
  exactly as an alias does, which is what makes joining an entity to a CTE
  over that same entity legal rather than an unaliased self-join.

- **`CYCLE`, for a walk over a graph rather than a tree.**

      let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })

  Without it Postgres walks a cycle until the connection dies; measured, an
  unguarded walk over a three-node cycle returns 20,000 rows and keeps going.
  With it, recursion stops at the row that closes the cycle, and that row — a
  duplicate of one already returned — is dropped when the CTE is read back;
  `includingCycleClosers: true` keeps it. Requires Postgres 14 or later.

  Whether you need it is not something a signature can tell you: a cycle is a
  property of the data, and the same walk is finite over a tree and endless
  over a graph. What the type can do is make asking for it one call.

  The marker columns `CYCLE` adds are invisible, because this package writes an
  explicit column list for every read and never `*`.

### Documentation

- The README's examples for everything 0.7.0 added — window functions, frames,
  set operations, scalar subqueries, NULLS placement — are compiled snippets
  now. They were prose, and `Snippets/CTEShapes.swift` still demonstrated the
  string-based CTE API while the README had moved on. Verified by renaming a
  function and watching the build fail at the snippet that used it.

## [0.7.0] - 2026-09-19

Analytic SQL: window functions with frames, set operations, and correlated
scalar subqueries. Four queries Postgres would have rejected at runtime are
now compile errors instead.

### Added

- **Window functions.** `.over` attaches to any `SelectExpression`, so every
  aggregate that existed before this release becomes a window function without
  gaining an overload — `sum()` answers "of the group", `sum().over(…)`
  answers "of the rows I am windowed with", from the same call site.

      rank().over(.partition(by: sale.customerID).order(by: sale.total.desc()))
      rank()       OVER (PARTITION BY customer_id ORDER BY total DESC)

  `rank()`, `rowNumber()`, `denseRank()` are free functions returning a value
  whose only method is `.over`, so the form Postgres rejects outside a window
  cannot be written. `lag`/`lead` sit on `Column`, because unlike the ranking
  functions they read their receiver, and return optionals — the first row of
  a partition has nothing behind it.

- **Frame clauses.** `rows(from:to:)` and `range(from:to:)`, which is the
  difference between a running total and a trailing one; without a frame a
  window is the whole partition, so a moving average was not expressible.
  Start and end are separate types, so two of Postgres's three frame errors
  cannot be spelled.

- **Set operations.** `union`, `unionAll`, `intersect`, `except` between two
  queries over the same entity. The combination is read as a derived table, so
  the result is an ordinary query again: `where`, `order`, `limit`, `count`
  and preloads all apply to the combined rows, and each branch keeps its own
  `ORDER BY` and `LIMIT`.

- **Correlated scalar subqueries.** `scalarCount()` and `scalar { … }` put
  another query in this one's SELECT list — a per-row count without grouping
  the outer query or spending a second round trip. Correlated like `exists()`:
  the inner predicate may name the outer row's columns.

- **`NULLS FIRST` / `NULLS LAST`** on any ordering. Postgres's default is not
  neutral — NULLs sort last for `ASC` and first for `DESC` — so "newest first,
  with the unfinished at the bottom" was previously unsayable.

### Changed

- **Serialization-failure retries now wait a jittered moment** (`0...10ms`,
  doubling) instead of looping straight back in. Two transactions that
  conflict are by definition concurrent, and retrying both instantly re-runs
  the same overlap; a pair could spend every attempt aborting each other.
  Worst case the default three attempts add under 30ms, and cancellation
  propagates out of the wait rather than being swallowed.

- **Four invalid queries are compile errors**, each naming the Postgres rule
  it breaks and the fix:

      Post.where { $0.viewCount.sum() > 5 }            // aggregate in WHERE
      …groupBy { … }.having { …sum().over() > 5 }      // window in HAVING
      Post.where { $0.viewCount.sum().over() > 5 }     // window in WHERE
      repo.all(Post.groupBy { $0.authorID })           // grouped rows fetched whole

  `CI/check-invalid-queries-fail.sh` compiles these on every push and fails if
  any of them builds.

### Source-breaking

Narrow, and each breaks code that was producing invalid SQL:

- `groupBy` returns `Query<Model, Grouped<Model>>` rather than
  `Query<Model, Model>`. Code that names the type explicitly needs updating;
  code that fetched a grouped query whole was generating SQL Postgres refuses.
  `select(into:)`, `count`, `exists` and joins all still work.
- Comparisons against an aggregate return `AggregatePredicate` rather than
  `Predicate`, which is what keeps them out of `where`. `having` takes both.

### Testing

- Property-based tests over generated predicate trees and builder programs,
  using PropertyBased — placeholder numbering, no value ever reaching the SQL
  text, clause composition, and last-call-wins.
- A differential suite: a generated predicate run against Postgres and against
  an evaluator here, row sets compared. The evaluator models three-valued
  logic, because that is where a disagreement would otherwise be ours.
- hangar-vapor is built against every commit here. Its own CI had not run
  since 2026-08-31, across three hangar releases.

## [0.6.0] - 2026-09-17

Transactional test isolation, as a shipped product. Additive: nothing in the
`Hangar` library itself changed, so upgrading cannot alter query behaviour.

### Added

- **`HangarTesting`** — a new library product carrying
  `withSandbox(_:logger:diagnostics:_:)`. It runs a body with a `Repo` pinned to
  one connection inside a transaction that is **always rolled back**, which is
  the Swift equivalent of Ecto's `Ecto.Adapters.SQL.Sandbox`: isolation comes
  from nothing ever being committed rather than from emptying shared tables
  between tests. Two things follow — there is no cleanup step, and because no
  test mutates shared state, suites can run **in parallel**.

  It is safe because the repo is built at transaction depth 1, so a
  `repo.transaction { }` inside the body renders as
  `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` rather than `BEGIN`/`COMMIT` — code under
  test cannot commit its way out of the sandbox, not even by opening its own
  transaction.

  Its own product, deliberately: a release build should never link a helper
  whose purpose is rolling transactions back.

  The doc comment carries what a sandbox *cannot* test, because each case is a
  green-but-wrong hazard rather than a failure: serialization retry never fires
  at depth ≥ 1; anything needing a second connection cannot see uncommitted
  rows; a test whose subject is commit durability keeps passing while measuring
  something else; sequences do not roll back; and a statement provoking a server
  error poisons the transaction (`SQLSTATE 25P02`), so every query after it
  throws.

  Assertions must be scoped to the rows a test created — a sandbox empties
  nothing, so committed rows remain visible.

## [0.5.1] - 2026-09-08

Documentation only.

### Fixed

- **A stale macro reference.** `MarkerMacros` described `@ID`/`@Column`/
  `@JSONB` as following "the same pattern as Flight's `@Autowired`". That
  macro was renamed to `@Inject` in flight 0.12.0.

## [0.5.0] - 2026-09-07

Found by building an application on the whole Flight stack and driving it from
outside: five of these are things a unit test cannot see, because they are
about which version resolved, what an error said, or whether a diagnostic
reached anyone.

### Breaking

- **`swift-changeset` is now required at `0.2.0`.** It was
  `.upToNextMinor(from: "0.1.0")`, which caps the whole stack: `flight-data`
  asks for `from: "0.1.0"`, the intersection is 0.1.x, and SwiftPM resolves it
  silently. Everything 0.2.0 added — `optimisticLock(_:)`, nested changesets,
  `ValidatedChanges.lock` and `.tableName`, `ChangesetConflictError` — was
  therefore unreachable from any application built on this stack, while
  swift-changeset's own README documented all of it. The cap was stale rather
  than load-bearing: the library compiled against 0.2.0 untouched and two test
  call sites needed the new `ValidatedChanges(tableName:…)` initializer.

- **`PostgresEnum` now implies `DynamicFilterConvertible`.** An enum-valued
  column could not go on a `DynamicallyFilterable` allowlist, so `?status=booked`
  — the most ordinary runtime filter an API has — did not compile. Everything
  the lookup needs is already required by `PostgresEnum`. Conformers that are
  not `Equatable` (nothing an enum with a raw value can be) would need to
  become so.

### Fixed

- **An optimistic-lock conflict said the row no longer exists.** A changeset
  carrying `optimisticLock(\.version)` renders `… WHERE id = 1 AND version = 7`;
  the writer that loses that race matches no row, and `update` reported
  `HangarError.staleModel` — "it was deleted concurrently or never inserted".
  An application maps that to 404 when the honest answer is 409 and "reload
  and retry". `ValidatedChanges.lock` says which column guarded the statement,
  and swift-changeset ships `ChangesetConflictError` for exactly this; both
  are now used.

- **Query diagnostics reported into nothing on the idiom that builds most
  repos.** `slowQueryThreshold` and `repeatedQueryThreshold` are opt-in and
  both reported through `logger?.warning(…)` — and `flight-data`'s `withRepo`,
  the bracket its own documentation recommends, constructs `Repo(connection:)`
  with no logger. Thirty copies of one statement inside
  `detectingRepeatedQueries` produced silence. A threshold the caller set
  deliberately now reports through a package logger; statement *tracing* still
  respects the optional logger.

- **A failed statement now says why.** PostgresNIO redacts its own
  `description`, so an error reaching an application's log carried no SQLSTATE,
  no message, no constraint name. The execute funnel reports the server's
  diagnostic fields — which carry no bound values — when a statement fails.

### Documentation

- `stream`'s lease: if its closure waits on something outside the database —
  an HTTP response, most obviously — the connection is held for as long as
  that takes, and a slow client sets the length.

## [0.4.0] - 2026-08-31

### Changed

- **`Table.query { }`'s closure now also receives the base entity's own
  columns as a second parameter**, so the common `let post = q.base` line
  before the first `q.join` is no longer needed:

  ```swift
  Order.query { q, order in
      let customer = q.join(Customer.self) { $0.id == order.customerID }
      ...
  }
  ```

  `q.base` still exists and returns the identical value, for a closure that
  wants to compute it somewhere other than the parameter list. **Breaking**:
  every existing single-parameter closure (`{ q in ... }`) needs the second
  parameter added — the compiler will point at each call site.

### Added

- **`QueryBuilder`'s setter methods are chainable.** `where`, `orWhere`,
  `order`, `groupBy`, `having`, `limit`, `offset`, `distinct()`,
  `distinct(on:)`, `lockForUpdate`, `lockForShare`, `withDeleted`,
  `onlyDeleted`, and all three `preload` overloads now return the builder
  (`@discardableResult`, so existing statement-style call sites are
  unaffected):

  ```swift
  q.where(post.published)
      .order(post.createdAt.desc())
      .limit(20)
  ```

- **`groupBy` takes any number of columns in one call, mixed types
  included** — `q.groupBy(post.id, post.title, author.name)` groups by a
  `Column<UUID>` and two `Column<String>`s together, the same
  parameter-pack technique `select` already uses for heterogeneous column
  lists. Replaces the old single-column overload rather than adding beside
  it, so there is no ambiguity between the two; a single column still reads
  as `q.groupBy(post.id)`. Repeated calls (chained or not) accumulate
  rather than replace.

## [0.3.0] - 2026-08-29

### Fixed

- **Soft-delete scope is no longer dropped by joins.** `Query` applied the
  deleted-row scope through `effectivePredicate` on every read path; every
  *join* form rendered `predicate` directly and carried no scope at all. The
  conversion from a `Query` copied the predicate, the grouping, the row lock,
  even the preloads — and left the scope behind. So
  `StoredFile.all.join(Author.self, ...)` silently included deleted files, and
  `StoredFile.onlyDeleted().join(...)` — an *explicit* request for deleted rows
  only — silently returned every row instead, an explicit scope inverted by
  composition. `JoinedQuery`, `JoinedQuery3` and `ComposedQuery` now all carry
  a `DeletedRowScope`, with `withDeleted()`/`onlyDeleted()` on each.

  The rule, in one sentence: **the base entity is scoped in `WHERE`, every
  soft-deletable joined table excludes its own deleted rows in its `ON`
  clause, and `withDeleted()` lifts both.** `ON` rather than `WHERE` for the
  joined side is what keeps a `LEFT JOIN` outer — in `WHERE` the condition
  discards exactly the unmatched rows the outer join exists to keep, turning
  it into an inner join with nothing to see. `.only` scopes the base alone: a
  trash view of files still joins to live owners.

  **This changes the SQL existing join queries render** whenever a
  soft-deletable entity is involved. That is the point — the previous
  behavior was a wrong answer, not a contract — but a query that was
  compensating with its own `deletedAt == nil` predicate will now say it
  twice (harmless), and one that was *relying* on deleted rows appearing
  needs `withDeleted()` spelled out.

- **`ColumnDefinition`'s equality now includes `isDeletedAt`**, which its own
  doc-comment ("equality over every recorded property") already claimed.

- **`HangarVapor.RunningClient.init` no longer takes a `logger`** it never
  used — `PostgresClient` was handed its `backgroundLogger` at construction,
  so the parameter was only ever an unused argument at the single call site.
  (Released separately in `hangar-vapor`.)

- **`scripts/test.sh`'s docker-missing path** referenced `$pg_port` before
  assigning it, so under `set -u` the error message itself errored; the
  suggested export line was mangled by nested quoting. Both fixed, and the
  vestigial valkey container — defined and cleaned up, never started, copied
  from the Flight scripts — is gone.

### Added

- **`Table.query { }`: joins of any width, built by name instead of by
  position.** `JoinedQuery`/`JoinedQuery3` fix the join count in the type,
  so a fourth table needs a fourth struct and every downstream closure takes
  one positional argument per table. `Table.query { }` hands a builder whose
  every `q.join` mints a fresh alias and returns that table's typed columns
  as an ordinary `let`, so five joins read as five bindings:

  ```swift
  Order.query { q in
      let order = q.base
      let customer = q.join(Customer.self) { $0.id == order.customerID }
      let item = q.join(OrderItem.self) { $0.orderID == order.id }
      q.where(customer.active)
      return q.select(into: OrderReport.self) {
          (id: order.id, customer: customer.name, quantity: item.quantity)
      }
  }
  ```

  The value it produces, `ComposedQuery<Base, Result>`, has two type
  parameters however many tables it joins: `SQLExpression`/`OrderTerm` carry
  only name strings, so nothing about rendering needs the joined Swift type
  once its ON-predicate is built. Self-joins need no `.alias(_:)` — collision
  is impossible by construction. `repo.all`/`one`/`count`/`exists`, preloads
  on the base-entity path, and the soft-delete scope all work as they do on
  the fixed-arity forms; `count`/`exists` follow the same
  changes-what-a-row-is subquery rules. Mutating the builder after
  `q.query()`/`q.select` has snapshotted it traps rather than being silently
  ignored.

  `JoinedQuery`/`JoinedQuery3` stay — their closure form is nicer for a quick
  two-table join — but the arity is frozen there. There will be no
  `JoinedQuery4`.

- **`withDeleted()`/`onlyDeleted()` as sugar on the entity itself**, beside
  `where`/`order`/`limit`: `StoredFile.onlyDeleted().where { ... }`. The
  README showed this spelling before it existed, which is exactly what the
  compiled Snippets are for — the soft-delete section now has one.

- **A composite-key diagnostic on `@Entity`.** An entity with more than one
  `@ID` batches its has-many/has-one preloads on the first key column alone.
  That is a defensible convention; taking it silently is not, so the macro
  now warns and names the column it chose.

- **`HangarIntrospection` refuses to describe a composite foreign key.** It
  reads `con.conkey[1]`/`con.confkey[1]` — the first column pair — so the
  comment it emitted for a two-column constraint described a one-column key
  that does not exist, and the `@BelongsTo` shape it suggested alongside
  would not have worked. Composite constraints now carry their width and
  name and generate a TODO comment naming both, in the same spirit as the
  unmappable-type refusal.

- **Ordering comparisons against nullable columns.** `<`, `>`, `<=`, `>=`
  now have `Column<V?>` overloads — `==`/`!=` already did. Without them, the
  most ordinary query a `@Deleted` column has ("purge everything soft-deleted
  before this date") did not compile, and neither did any range over a
  nullable timestamp (`closed_at`, `published_at`, `resolved_at`). The
  right-hand side stays non-optional: `deletedAt < nil` has no meaning in
  SQL, and keeping `nil` out of these signatures is what guarantees `== nil`
  still renders `IS NULL` rather than being captured by a new overload.
- **`debugSQL` coverage for every write and join shape added since the
  round-1 pass.** `Query.debugDeleteSQL()`, `Query.debugUpdateSQL(set:)`,
  `Array<Table>.debugInsertSQL()`, and `JoinedQuery3.debugSQL` /
  `.renderedQuery()` — bulk delete, bulk update, batch insert, and
  three-table joins previously had no way to see the SQL they render to
  without executing them. Added mainly to let `hangar-bench` measure these
  shapes client-side the same way every other query shape already was, but
  real API on its own: the same escape hatch `debugSQL` already gave every
  single-table and two-table query.
- **Benchmark coverage for everything Phase 0–7 and the 0.2.0 release
  added.** `hangar-bench` and `BENCHMARKS.md` had not been touched since
  before that work landed, so none of it — bulk delete/update, batch
  insert, three-table joins, pagination, soft delete, query diagnostics —
  had a measured number. Batch insert turned out to be the largest ratio in
  the whole file (~24× over individual round trips); soft delete and query
  diagnostics turned out to cost nothing measurable when idle, which is
  itself the finding worth having on record rather than assumed.

- **A `ComposedQuery` vs. `JoinedQuery3` comparison in `BENCHMARKS.md`**, the
  numbers `hangar-bench`'s own comment was already pointing at. The erased
  form is the cheaper one client-side (~1.15× rendering, ~1.24× projected,
  both reproduced across two runs) and indistinguishable end to end, where
  the round trip dominates. The bench's fixture seeding now goes through the
  batch insert rather than 480 individual round trips.

### Changed

- **The query-duration `Timer` stays per statement, on the record.** Caching
  the per-operation timers was tried and reverted:
  `Timer(label:dimensions:)` binds to whichever factory `MetricsSystem` held
  at construction, so a cached set binds to whatever was bootstrapped when
  the first query ran — and a process that bootstraps its backend afterwards
  then records into the no-op handler forever, silently. A library cannot
  control that ordering. Trading a robustness property for an allocation
  nothing has measured is the wrong direction for this package; the reason
  is now a comment in `Repo.execute` rather than something to re-discover.

- **Every database-touching test suite is gated.** `PostgresIntegrationSuite`
  now carries `.enabled(if: TestDatabase.isConfigured)`, which applies to
  everything nested inside it, and the six free-standing suites carry it
  directly. Nine of twenty-eight test files had the trait and seven that
  needed it did not — and a missing gate does not skip, it fails the run with
  `.notConfigured`, turning an unconfigured CI secret into what reads as a
  broken build. `swift test` with no `HANGAR_TEST_DATABASE_URL` is clean
  again.

## [0.2.0] - 2026-08-25

### Added

- **Soft delete.** `@Deleted var deletedAt: Date?` makes an entity
  soft-deletable: `repo.delete` stamps the column instead of removing the
  row, `repo.restore` clears it, and every read path excludes stamped rows by
  default. `withDeleted()` and `onlyDeleted()` select the other two views.
  The default applies uniformly — `all`, `one`, `count`, `exists`, joins,
  projections and preloads — because a soft delete that one code path forgets
  is worse than none: the row looks gone in a list and reappears in a count,
  and nothing errors. Preloaded children are excluded too, which is the case
  most implementations miss.
- **Common table expressions.** `with(_:as:)` and `withRecursive` define
  them; `reading(from:)` makes one the query's source, rendered as
  `FROM "cte" AS "entity_table"` so every column reference, ordering,
  predicate and preload downstream resolves against it unchanged. A
  non-recursive body may be a typed `Query`; a recursive one takes a typed
  anchor and a raw step, because the step refers to the CTE being defined and
  no entity's columns can describe that. `count`, `exists`, `delete` and
  `update` all carry the clause. A bulk write may be *fed* by a CTE but is
  refused if it tries to target one — `DELETE FROM "cte"` deletes nothing
  real.
- **Pagination.** `repo.page(query, PageRequest(...))` returns a `Page`
  carrying the slice and the total behind it. The count and the slice run
  sequentially rather than concurrently: two queries from one pool under a
  request-scoped connection is how a pool deadlocks under load.
- **Query diagnostics.** `QueryDiagnostics` surfaces slow queries against a
  configurable threshold, and `detectingRepeatedQueries` reports the N+1
  shape — the same statement issued repeatedly within one scope — which is
  the problem preloading exists to solve and the one nothing was measuring.
- **`EXPLAIN`.** `repo.explain(query, mode:)` returns the plan as text, or
  `ANALYZE`/`BUFFERS`/`VERBOSE` output. The diagnostics above say which query
  is slow; this says why.
- **Schema introspection** (`HangarIntrospection`, a separate product).
  `SchemaIntrospector` reads `pg_catalog` and `EntityGenerator` emits
  `@Entity` types from a live database — the path into Hangar for a schema
  that already exists. A separate product on purpose: generating models is a
  build-time chore, and nothing depending on Hangar at runtime should carry
  it.

### Fixed

- **Projections silently dropped the soft-delete scope.** `Query.rebinding` —
  the pivot `.select {}` goes through — copied every clause except
  `deletedRows`, so `.withDeleted().select {}` quietly went back to hiding
  deleted rows and `.onlyDeleted()` inverted to mean its opposite. A
  projection answering a different question than the query it came from is
  the class of bug this package refuses to ship; pinned by its own test.

### Changed

- `SQLFragment` rendering, the fragment-predicate path and the
  transaction escape hatch's statement rendering now share one
  implementation instead of three copies of the same parts loop.

### Infrastructure

- `scripts/test.sh` starts a throwaway Postgres, runs the whole suite through
  `CI/run-tests.sh`, and tears it down.
- `CI/run-tests.sh` reports both testing dialects. `swift test` exits non-zero
  for either, but its *output* does not say so in one place — which is how 13
  failing macro fixtures hid behind a green swift-testing summary.
- The database tests serialize against a shared lock; `withRepo` truncates
  shared fixture tables, so parallel suites were racing each other.
- A macOS build job, and the private-package token is now optional — every
  dependency is public, so a fork with no secret resolves fine.

## [0.1.0] - 2026-08-24

### Added

- **`@HasMany(through:)`** — many-to-many through a join table.
  `@HasMany(through: PostTag.self, from: \PostTag.postID, to: \PostTag.tagID)`
  preloads with two batched queries (join table, then related table), never a
  SQL join — the same shape as every other preload. The related key follows
  the `\Related.id` convention `@BelongsTo`'s `references` default already
  set. Per-parent ordering honors the tuned child query; duplicate join rows
  yield duplicate children; a join row referencing a vanished child is
  skipped, matching direct has-many's inner-join semantics. `.preload(\.tags)`
  is identical at the call site whichever kind the association is.
- **Two macro diagnostics that were silent failures.** `@BelongsTo` with an
  array argument (a has-many shape wearing the wrong attribute) used to
  escape into the expansion as uncompilable generated code with a baffling
  error; it now diagnoses at the property (`entity.belongstotype`). And
  `through:` on `@BelongsTo`/`@HasOne` diagnoses as `@HasMany`-only
  (`entity.throughkind`); missing `from:`/`to:` diagnoses `entity.throughkeys`.
- **Three-table joins.** `.join`/`.leftJoin` on any two-table join adds a
  third table, the on-closure and every later composition closure seeing all
  three column sets. Aliases work on any side, the ambiguity guard extends
  three ways, projections and preloads carry through, and `count`/`exists`
  follow the same clause rules as everywhere else. Ordinary generics, not a
  parameter-pack generalization: a compile spike confirmed a stored pack
  cannot be re-expanded into the on-closure call in this Swift version, so
  the pack form would compromise exactly the ergonomics that matter.
- **`DISTINCT ON`.** `distinct(on: { $0.authorID })` on single-table and
  joined queries alike — the "newest row per group" shape. Last-call-wins
  with `.distinct()`, counted through a subquery, refused by bulk writes.
- **`exists` for joined queries**, which had `count` but no `exists`.
- **Self-joins, via table aliases.** `Post.alias("parent").join(Post.alias("child"), on: ...)`
  renders `FROM "posts" AS "parent" JOIN "posts" AS "child"`, with every
  column reference — in the ON condition, later `.where`/`.order`/`.groupBy`
  closures, and the base entity's select list — qualified by its alias.
  Aliases are equally allowed on ordinary joins. An unaliased self-join is
  still refused, now with the remedy named; two sides aliased to the same
  name are refused too. The `@Entity`-generated `Columns` struct gained
  `init(table:)` (the `AliasableColumns` conformance) to make aliased column
  sets constructible; `Table.QueryColumns` is now constrained to it, which
  is source-breaking only for hand-written `Table` conformances — `@Entity`
  regenerates automatically.
- **Transaction isolation levels and retry.**
  `repo.transaction(isolation: .serializable) { }` applies the level to the
  outermost `BEGIN` (nested calls are savepoints and cannot change it), and
  `transaction(isolation:retryingOnSerializationFailure:_:)` re-runs the
  whole transaction on SQLSTATE `40001`/`40P01` — the standard SERIALIZABLE
  pattern, verified by a real write-skew contention test.
- **In-transaction escape hatch.** `repo.execute("SET LOCAL ...")` runs one
  raw statement, bind-safe under `SQLFragment`'s interpolation rules, on the
  transaction's own connection — which is what `SET LOCAL`, advisory locks,
  and DDL need, with no raw connection ever exposed.
- **Row locks as first-class query modifiers.** `Query.lockForUpdate()` /
  `.lockForShare()`. A locking read always routes to the primary, carries
  through joins rather than being silently dropped, is stripped from `count`
  (counting must not lock), and is refused by bulk writes (which take their
  own locks).
- **Batch insert.** `repo.insert([models])` — one multi-row `VALUES`
  statement, one round trip, results returned in input order with generated
  columns read back. Atomic as any single statement is: a constraint
  violation anywhere inserts nothing.
- **Bulk `update(query, set:)`.** One statement across every matching row,
  with typed, bound assignments and the row count returned:
  `repo.update(Post.where { $0.published == false }) { ($0.published.set(to: true)) }`.
  Same clause rules as bulk delete.
- **Bulk `delete(query)`.** `repo.delete(Session.where { $0.expiresAt < .now })`
  deletes every matching row in one statement and returns the count. A query
  carrying a clause DELETE cannot honor — LIMIT, ORDER BY, GROUP BY, HAVING,
  DISTINCT — throws `HangarError.bulkWriteClause` rather than executing with
  the clause silently dropped.
- **Array column types.** `@Column var tags: [String]` maps to `text[]`, and
  likewise for `Bool`, `Int`/`Int16`/`Int32`/`Int64`, `Float`, `Double`,
  `UUID`, and `Date` elements — exactly the set PostgresNIO can code into a
  Postgres array. `Decimal` and `Data` have no array coding upstream, so
  `numeric[]`/`bytea[]` columns remain unsupported.

### Added (safety)

- **Escaped streams fail loudly.** `PostgresRowStream` is an ordinary
  `Sendable` struct, and Swift's `AsyncSequence` cannot be conformed to by a
  non-escapable type — so copying one out of its `stream { }` closure cannot
  be a compile error in this language version (verified against the 6.2.3
  stdlib's protocol declarations). It is now a runtime one: the connection
  lease expires when the closure returns, and the first `next()` after that
  throws `HangarError.streamLeaseExpired` instead of reading rows from a
  connection another query now owns.

### Changed

- **`MultiValues`' subscript throws instead of trapping.** A step reading a
  key whose step hasn't run, or a mistyped key, now fails that Multi's
  transaction and reports through `MultiResult.failure` — the right blast
  radius for a wiring bug discovered inside a live transaction is one rolled
  back transaction, not an aborted process. Call sites gain a `try`.

### Fixed

- **`SQLFragment` columns render table-qualified in multi-table scopes.**
  A fragment like `SQLFragment("char_length(\(p.title)) > \(n)")` inside a
  join previously rendered a bare `"title"` — ambiguous at best, silently
  resolved to the wrong table at worst. Qualification is now decided at
  render time, exactly as for columns outside fragments.

### Fixed

- **Joined `count` honored none of GROUP BY / HAVING / DISTINCT.** The
  single-table `count` was fixed in the last pass; the joined one still
  hand-rolled its SQL and ignored all three. Both now share the same rule:
  clauses that change what a row is count through a subquery.
- **`count` over a grouped, unprojected query now emits valid SQL.** It
  used to render the full column list inside the subquery — which Postgres
  rejects, since ungrouped columns can't appear — so the count that should
  have said "2 groups" said "ERROR". The grouping expressions themselves
  are the inner select list now: one row per group is exactly what is being
  counted.

### Fixed — silent wrong answers

Three bugs that rendered valid SQL and returned the wrong result. Nothing
threw and nothing logged, which is what makes this class of bug worth its own
test suite.

- **A join discarded the `GROUP BY` and `HAVING` it was composed from.**
  `Post.groupBy { … }.join(…)` produced an ungrouped, unfiltered query. Building
  the join first happened to work, so composition order silently changed the
  result — and the documented example was written in the order that broke.
- **`count` and `exists` ignored `GROUP BY`, `HAVING`, and `DISTINCT`.** Each
  changes what a row is, so counting without them answers a different question:
  a `count` over a grouped query returned 3 where the correct answer was 1.
  Those queries are now counted as a subquery. Ordering, limit, and offset are
  still ignored, because they do not change how many rows match.
- **A connection-bound `Repo` committed its caller's transaction.**
  `Repo(connection:)` assumed it was outermost, so `transaction { }` emitted a
  literal `BEGIN`/`COMMIT`. Handed a connection already inside a transaction —
  exactly what a framework integration does — Postgres ignored the redundant
  `BEGIN` and the `COMMIT` ended the caller's transaction, making writes the
  caller then rolled back durable.

  `Repo(connection:inTransaction:)` fixes it. Hangar cannot detect this
  itself, because PostgresNIO does not expose the connection's transaction
  status, so the caller declares it.

### Changed

- **`JoinedQuery2` is now `JoinedQuery`.** The `2` was arity, not a version,
  and every reader assumed otherwise.
- `HangarError` conforms to `LocalizedError`, so `localizedDescription` carries
  the real message rather than a Foundation placeholder.
- Diagnostic messages no longer cite internal design-document sections.

### Removed

- `SQLRenderer_quoteForTest`, a public global that existed only for a test that
  can use `@testable`.
- `TableSchema.insertPlaceholders`, computed for every schema and never read.

### Added

- `SilentWrongAnswerTests`, pinning all three bugs above — including a test
  that deliberately demonstrates the *hazardous* default of
  `Repo(connection:)`, so the parameter cannot be removed without a red test
  explaining what it was for.
- DocC catalog with two guides: preloading, and transactions and connections.
- LICENSE, CI with a Postgres service container, CONTRIBUTING, CHANGELOG.

### Documentation and test coverage

- **Every public declaration is documented — 284 of 284, from 42%.** The
  quality bar is the one the already-documented half set: explain the what
  and the why, an example where non-obvious, never a restated signature.
- **Every macro diagnostic has a fixture — 20 of 20, from 7 of 18.** Each
  misuse's exact message, line, and column is pinned, so a rewording or a
  silently-vanished diagnostic fails a test instead of shipping. The two
  diagnostics added this cycle (`entity.belongstotype`, `entity.throughkind`/
  `entity.throughkeys`) are pinned alongside the eleven that never had one.
- The DocC guides no longer describe closed gaps as open: the transactions
  guide now documents isolation levels, retry, `execute`, and row locks; the
  preloading guide documents `@HasMany(through:)`.

### Documentation

- README rewritten for an external reader; it was a monorepo status log. It now
  states plainly what is missing — bulk writes, an in-transaction escape hatch,
  isolation levels, CTEs, three-table joins.
- All internal design-document references removed from source, tests, README,
  and benchmarks, including ones in test names that appear in CI output.
