# Transactions and connections

Nesting, savepoints, and the one thing you must tell a connection-bound repo.

## Overview

``Repo/transaction(isolation:statementTimeout:_:)`` runs a body inside a transaction. Returning commits;
throwing rolls back:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)
    try await tx.insert(payment)      // a throw here discards the order too
}
```

The `tx` handed to the body is a repo bound to the transaction's connection.
Use it — not the outer repo — for everything inside, or the work runs outside
the transaction.

Whatever the body returns is the call's result, once the commit has
succeeded:

```swift
let saved = try await repo.transaction { tx in
    try await tx.insert(order)
}
```

The result is discardable, so a body run only for its effects needs no
`_ =` in front of it.

## Nesting uses savepoints

A `transaction` inside a `transaction` becomes a `SAVEPOINT`, so an inner
failure can be caught and handled without discarding the outer work:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)

    do {
        try await tx.transaction { inner in       // SAVEPOINT
            try await inner.insert(optionalExtra)
        }
    } catch {
        // The savepoint rolled back. The order is still there.
    }
}
```

Savepoint names are generated from the nesting depth, never from user input.

## A failure you catch still aborts the transaction

Once any statement fails, Postgres aborts the whole transaction: every later
statement is refused, and the `COMMIT` at the end is answered with `ROLLBACK`
— without an error. Catching the failure in the body does not undo that:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)
    do {
        try await tx.insert(duplicateCoupon)     // fails: unique violation
    } catch {
        // The transaction is already aborted. `order` will not be saved.
    }
}
```

Hangar checks what `COMMIT` actually did, so this throws
``HangarError/transactionAborted(cause:)`` naming the statement that failed,
rather than returning as if the order had been saved. A savepoint's `RELEASE`
in the same state, and any statement after the failure, report the same
error. To survive an expected failure, run it in a nested `transaction` — a
savepoint — as in the previous section; rolling back to the savepoint leaves
the outer transaction healthy.

## Database errors are typed

Server errors arrive as ``DatabaseError``: a ``DatabaseError/Kind`` for the
cases worth branching on (unique, foreign-key, check and not-null
violations, serialization failures, deadlocks, lock timeouts), plus the
SQLSTATE, table, constraint and column *names*:

```swift
do {
    try await repo.insert(user)
} catch let error as DatabaseError where error.isUniqueViolation {
    // error.constraint == "users_email_key", error.columnName == "email"
}
```

Its description never includes row values. It is metadata only: kind,
SQLSTATE, table, constraint and column names. The server's own text can
quote data (a unique violation's detail quotes the row, a failed cast quotes
the value), so it stays on ``DatabaseError/message`` and
``DatabaseError/underlying`` for code that wants it deliberately. The
exception is an error about the statement itself, SQLSTATE class 42 or 0A,
whose message names only what the SQL names and is part of the description:
`database error (SQLSTATE 42703): column "nmae" does not exist`. For an
undefined column or table, ``DatabaseError/hint`` adds `HGR-QUERY-4114`: the
database may be behind the application's migrations.

Every statement the server rejects is logged once, with that metadata and
the SQL as sent (placeholders, never values). The log goes to the repo's
logger, or to a `hangar.diagnostics` logger when the repo has none. The
level follows the meaning:

- A constraint violation (class 23) is `info`. It is how an application
  enforces its invariants, and the caller decides whether it is an error.
- A serialization failure or deadlock (40001, 40P01) is `notice`. Running
  the transaction again is the remedy.
- Everything else is `error`.

A statement that never got an answer — the server refused the connection,
the network dropped it, the pool was closed — is a
``DatabaseConnectionError``, whose description says why:
`could not connect to the database: connection refused (10.0.0.5:5432)`.
Other client-side failures, such as a cell that does not decode, keep their
own types.

## Mapping failures to responses

Three properties sort failures the way an HTTP layer answers them:

- ``DatabaseError/isTransient`` and ``DatabaseConnectionError/isTransient``:
  the same request can succeed later — a serialization failure, a deadlock,
  a lock or statement timeout, a server short of connections or restarting,
  an unreachable database. A 503.
- ``HangarError/isClientInput``: a dynamic filter named a field outside the
  allowlist or sent a value of the wrong type. A 400.
- ``DatabaseError/isRetryable``: narrower than transient — the failures whose
  documented remedy is running the transaction again at once.

## Binding a repo to a connection you own

A repo normally holds a pool. It can instead be pinned to a single connection
you manage — the shape a pool that leases a connection per operation uses to
hand one to its caller:

```swift
let repo = Repo(connection: connection)
```

> Important: **If that connection is already inside a transaction, say so.**
>
> ```swift
> Repo(connection: connection, inTransaction: true)
> ```
>
> At the default the repo believes it is outermost, so `transaction { }` emits
> a literal `BEGIN`/`COMMIT`. Postgres warns and ignores the redundant
> `BEGIN` — and the `COMMIT` then ends *your* transaction. Work you intended
> to roll back is durable instead, with nothing thrown and nothing logged.
>
> With `inTransaction: true` it nests as a savepoint, which is what it should
> have been.
>
> Hangar cannot detect this itself: PostgresNIO does not expose the
> connection's transaction status. The caller knows, so the caller says.

``Repo/isInTransaction`` reports what the repo believes, which is a useful
thing to assert in an integration's tests.

A pool that leases connections cannot otherwise tell a connection in the
middle of a transaction from an idle one, because Hangar sends `BEGIN` and
`COMMIT` itself. Pass a ``TransactionObserver`` so the pool never hands an
open transaction to the next borrower:

```swift
let repo = Repo(connection: connection, transactionObserver: TransactionObserver(
    began: { lease.markInTransaction() },
    ended: { lease.markIdle() }))
```

`began` runs before `BEGIN` is sent, and `ended` runs once `COMMIT` or
`ROLLBACK` has been answered. Only the outermost transaction is reported, not
savepoints. A task that dies in between, or a `ROLLBACK` that fails, leaves
the owner with `began` and no `ended`. That is the connection to roll back
or discard.

## Isolation levels and retry

The level rides on the outermost `BEGIN` — nested calls are savepoints and
cannot change it:

```swift
try await repo.transaction(isolation: .serializable) { tx in ... }
```

Under `SERIALIZABLE`, concurrent conflicting transactions fail with SQLSTATE
`40001` (``DatabaseError/Kind/serializationFailure``), and any isolation level
can pick a deadlock victim (`40P01`) — that is the isolation level working as designed, and the remedy is
to run the whole transaction again:

```swift
try await repo.transaction(
    isolation: .serializable, retryingOnSerializationFailure: 3
) { tx in ... }
```

The body must be safe to run more than once; side effects outside the
database do not roll back, so keep them out of retried bodies.

The number is the total attempts, the first included: `3` is at most two
retries, each on a fresh transaction after a short randomised wait. Only
``DatabaseError/isRetryable`` failures (40001, 40P01) are retried, whether a
statement or the `COMMIT` raised them; a lock or statement timeout is not. A
retryable failure the body *catches* is not retried either: the transaction
is aborted regardless, and what reaches the retry is
``HangarError/transactionAborted(cause:)``. Called inside another
transaction, it does not retry at all — it becomes a savepoint, and only the
outermost transaction can be run again.

## Raw SQL on the transaction's connection

``Repo/execute(_:)`` runs one statement under `SQLFragment`'s interpolation
rules — literals become SQL, values become binds, only `\(raw:)` can smuggle
text. Inside `transaction { }` it runs on **that transaction's connection**,
which is what `SET LOCAL`, advisory locks, and DDL need:

```swift
try await repo.transaction { tx in
    try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
    try await tx.execute("SELECT pg_advisory_xact_lock(\(42))")
    ...
}
```

## Row locks

`FOR UPDATE` is first-class, not raw SQL — typed, discoverable, and routed
to the primary:

```swift
try await repo.transaction { tx in
    let account = try await tx.one(Account.where { $0.id == id }.lockForUpdate())
    // the row is ours until commit
}
```

A lock composed before a join carries through; `count` strips it (counting
must not lock); bulk writes refuse it — they take their own locks.
