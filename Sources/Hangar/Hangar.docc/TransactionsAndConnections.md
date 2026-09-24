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

Its description never includes row values — the server's detail for a
unique violation quotes the row, so it stays on
``DatabaseError/underlying`` for code that wants it deliberately. Errors that
never reached the server (a lost connection, a decoding failure) keep their
own types.

## Binding a repo to a connection you own

A repo normally holds a pool. It can instead be pinned to a single connection
you manage — the shape a framework uses to bind one to a request scope:

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
