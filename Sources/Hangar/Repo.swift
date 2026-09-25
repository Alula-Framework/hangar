import Foundation
import Logging
import Metrics
import PostgresNIO

/// Execution against PostgresNIO. `Repo` takes a connection
/// source and nothing else — it has no idea what a request, a job, or a
/// scope is; that's the caller's business, which is what keeps Hangar
/// Alula-independent.
public struct Repo: Sendable {
    /// Where statements run: the pooled client(s), or — inside
    /// `transaction { }` — the one connection the transaction owns, with
    /// its nesting depth (0 = outermost `BEGIN`, ≥1 = savepoints).
    enum Backend: Sendable {
        /// `replica` non-nil means reads route there; writes and
        /// transactions always use `primary`.
        case client(primary: PostgresClient, replica: PostgresClient?)
        case transaction(PostgresConnection, depth: Int)
    }

    /// Whether a statement reads or writes — what read-replica routing
    /// keys on. Everything inside a `transaction { }` ignores this and
    /// uses the transaction's connection: a read inside a transaction must
    /// see that transaction's uncommitted writes.
    enum Intent: String, Sendable {
        case read
        case write
    }

    let backend: Backend
    /// Inside a transaction: the statements that failed, so a transaction
    /// Postgres has aborted can say why when it refuses to commit. Shared by
    /// every repo of one transaction, savepoints included.
    let transactionLedger: TransactionLedger?
    /// Told when this repo opens and closes an outermost transaction on its
    /// pinned connection — see ``TransactionObserver``.
    let transactionObserver: TransactionObserver?
    /// Passed through to PostgresNIO per query, and the sink for Hangar's
    /// own per-query debug line; `nil` disables both.
    let logger: Logger?

    /// Slow-query and repeated-query reporting. Off unless set — see
    /// ``QueryDiagnostics``.
    public var diagnostics = QueryDiagnostics()

    /// A repo over one client — every read and write goes to it.
    public init(client: PostgresClient, logger: Logger? = nil) {
        self.backend = .client(primary: client, replica: nil)
        self.transactionLedger = nil
        self.transactionObserver = nil
        self.logger = logger
    }

    /// Read-replica routing: `all`/`one`/`count`/`exists`/`stream`
    /// go to `replica`; writes and everything inside a `transaction` block
    /// go to `primary`. The single-client initializer keeps both pointing
    /// at the same place.
    public init(primary: PostgresClient, replica: PostgresClient, logger: Logger? = nil) {
        self.backend = .client(primary: primary, replica: replica)
        self.transactionLedger = nil
        self.transactionObserver = nil
        self.logger = logger
    }

    init(
        transaction connection: PostgresConnection, depth: Int, ledger: TransactionLedger,
        logger: Logger?
    ) {
        self.backend = .transaction(connection, depth: depth)
        self.transactionLedger = ledger
        self.transactionObserver = nil
        self.logger = logger
    }

    /// A repo pinned to one specific connection — for integration layers
    /// that manage connection lifetime themselves (e.g. Alula's
    /// request-scoped connections, the design). Every statement runs on
    /// this connection; `transaction { }` issues `BEGIN`/`COMMIT` on it
    /// (nesting becomes savepoints as usual), and there is no replica
    /// routing — the connection *is* the destination.
    ///
    /// The caller owns checkout and return; the repo must not outlive the
    /// connection's lease.
    /// - Parameters:
    ///   - connection: The connection every statement runs on.
    ///   - logger: Where statements are logged at debug level. `nil` stays
    ///     quiet.
    ///   - inTransaction: Whether `connection` is **already** inside a
    ///     transaction the caller opened.
    ///
    ///     This matters more than it looks. At `false` — the default — the repo
    ///     believes it is outermost, so `transaction { }` emits a literal
    ///     `BEGIN`/`COMMIT`. If the connection was already inside someone
    ///     else's transaction, Postgres warns and ignores the redundant
    ///     `BEGIN`, and the `COMMIT` then **ends the caller's transaction** —
    ///     so work the caller intended to roll back becomes durable.
    ///
    ///     Pass `true` when handing a connection to this repo from inside an
    ///     open transaction, as a framework integration binding a
    ///     request-scoped connection does. `transaction { }` then nests as a
    ///     savepoint, which is what it should have been.
    ///   - transactionObserver: Told when this repo opens and closes an
    ///     outermost transaction on `connection` — for a pool that must not
    ///     hand the connection on while one is open. See
    ///     ``TransactionObserver``.
    public init(
        connection: PostgresConnection,
        inTransaction: Bool = false,
        logger: Logger? = nil,
        transactionObserver: TransactionObserver? = nil
    ) {
        self.backend = .transaction(connection, depth: inTransaction ? 1 : 0)
        self.transactionLedger = inTransaction ? TransactionLedger() : nil
        self.transactionObserver = transactionObserver
        self.logger = logger
    }

    /// True when this repo is operating inside an open transaction.
    ///
    /// That covers the repo handed to a `transaction { }` body, and a
    /// connection-bound repo constructed with `inTransaction: true`. One at
    /// the default `inTransaction: false` reports false until its own
    /// `transaction { }` opens one.
    public var isInTransaction: Bool {
        if case .transaction(_, let depth) = backend { return depth > 0 }
        return false
    }

    // MARK: Reads

    /// Full-model fetch: decodes rows, then runs the query's preloads
    /// — one batched query per association, grouped and assigned
    /// into each model's `Loadable`.
    // swift-format's AmbiguousTrailingClosureOverload rule has no opinion here,
    // but the shape is the same one used for `where`: an overload that exists
    // only to be chosen for the wrong argument and refuse it by name.
    @available(
        *, unavailable,
        message: """
            [HGR-QUERY-4004] A grouped query has no whole rows to fetch — GROUP BY collapses
            them, and Postgres answers "column ... must appear in the GROUP BY clause or be
            used in an aggregate function". Choose the columns instead:
            `.select(into: Summary.self) { ($0.someColumn, $0.other.count()) }`, or ask
            about the groups with `count` / `exists`.
            See https://github.com/Alula-Framework/hangar/blob/main/Diagnostics/HGR-QUERY-4004.md
            """
    )
    public func all<M: Table>(_ query: Query<M, Grouped<M>>) async throws -> [M] {
        fatalError("unavailable")
    }

    public func all<M: Table>(_ query: Query<M, M>) async throws -> [M] {
        var models: [M] = try await rows(
            for: SQLRenderer.select(query), intent: query.rowLock == nil ? .read : .write,
            operation: "select")
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models
    }

    /// Projected fetch: `Result` was changed by `.select {}`, and the
    /// selection installed the row decoder for it.
    public func all<M, R>(_ query: Query<M, R>) async throws -> [R] {
        let selection = try validatedSelection(of: query)
        let sequence = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        var results: [R] = []
        for try await row in sequence {
            results.append(try selection.decode(row))
        }
        return results
    }

    /// At most one row, or `nil`. More than one match is an error, not a
    /// silent first-row pick. Preloads apply to the returned model.
    // swift-format's AmbiguousTrailingClosureOverload rule has no opinion here,
    // but the shape is the same one used for `where`: an overload that exists
    // only to be chosen for the wrong argument and refuse it by name.
    @available(
        *, unavailable,
        message: """
            [HGR-QUERY-4004] A grouped query has no whole rows to fetch — GROUP BY collapses
            them, and Postgres answers "column ... must appear in the GROUP BY clause or be
            used in an aggregate function". Choose the columns instead:
            `.select(into: Summary.self) { ($0.someColumn, $0.other.count()) }`, or ask
            about the groups with `count` / `exists`.
            See https://github.com/Alula-Framework/hangar/blob/main/Diagnostics/HGR-QUERY-4004.md
            """
    )
    public func one<M: Table>(_ query: Query<M, Grouped<M>>) async throws -> M? {
        fatalError("unavailable")
    }

    public func one<M: Table>(_ query: Query<M, M>) async throws -> M? {
        var models: [M] = try await rows(
            for: SQLRenderer.select(probing(query)), intent: query.rowLock == nil ? .read : .write,
            operation: "select")
        guard models.count <= 1 else {
            throw HangarError.tooManyRows(table: M.schema.name)
        }
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models.first
    }

    /// At most one projected row; more than one throws `tooManyRows`.
    public func one<M, R>(_ query: Query<M, R>) async throws -> R? {
        let results: [R] = try await all(probing(query))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: M.schema.name)
        }
        return results.first
    }

    /// The query `one` actually runs.
    ///
    /// `one` needs a second row to be able to say "more than one matched",
    /// so it asks for two — but only when the caller has not already said
    /// how many they want. Imposing `LIMIT 2` over an explicit `.limit(1)`
    /// and then raising ``HangarError/tooManyRows(table:)`` about the extra
    /// row contradicts the caller and makes "the head of an ordered list"
    /// — a waitlist, a queue, a leaderboard — inexpressible through `one`
    /// as soon as the list has two entries. A caller's own limit is
    /// honored; `tooManyRows` then means what it says.
    private func probing<M, R>(_ query: Query<M, R>) -> Query<M, R> {
        query.rowLimit == nil ? query.limit(2) : query
    }

    // MARK: Streaming
    //
    // `all` materializes every row; over a large result set that is the
    // memory footprint of the whole table. `stream` decodes lazily off
    // PostgresNIO's row sequence instead, so a million-row export costs one
    // row at a time.
    //
    // Two deliberate limits, both consequences of laziness rather than
    // oversights: preloads do not run (they need the full parent set to
    // batch, which is exactly what streaming refuses to hold), and the
    // sequence must be consumed inside the call — the connection is leased
    // for the duration.
    //
    // That lease is worth one more sentence, because it is easy to hand its
    // length to someone else. If the closure waits on anything outside the
    // database — writing an HTTP response, most obviously — the connection
    // is held for as long as *that* takes, and the pace is then the
    // consumer's rather than yours: a client reading a CSV export at 20 KB/s
    // holds a connection for the whole download, and enough of them hold the
    // pool. Page the query and release between batches, or give exports
    // their own small pool, when the reader is not one you control.

    /// Streams full models, decoding one row at a time. Preloads on the
    /// query are **not** applied — batching needs every parent at once; use
    /// `all` when you need associations.
    public func stream<M: Table, T>(
        _ query: Query<M, M>,
        _ body: (PostgresRowStream<M>) async throws -> T
    ) async throws -> T {
        let rows = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        let lease = StreamLease()
        defer { lease.expire() }
        return try await body(
            PostgresRowStream(rows: rows, decode: { try M(from: $0) }, lease: lease))
    }

    /// Streams a projection, decoding one row at a time.
    public func stream<M, R, T>(
        _ query: Query<M, R>,
        _ body: (PostgresRowStream<R>) async throws -> T
    ) async throws -> T {
        let selection = try validatedSelection(of: query)
        let rows = try await execute(
            SQLRenderer.select(query).postgresQuery(),
            intent: query.rowLock == nil ? .read : .write, operation: "select")
        let lease = StreamLease()
        defer { lease.expire() }
        return try await body(PostgresRowStream(rows: rows, decode: selection.decode, lease: lease))
    }

    private func validatedSelection<M, R>(of query: Query<M, R>) throws -> Selection<R> {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: M.schema.name,
                reason:
                    "the query's Result is not \(M.self) but no .select {} installed a projection — this is a Hangar bug."
            )
        }
        if let invalid = selection.invalid {
            throw invalid
        }
        return selection
    }

    /// How many rows match the query's conditions. Ordering, limit, and
    /// offset are ignored.
    public func count<M, R>(_ query: Query<M, R>) async throws -> Int {
        try await scalar(
            Int.self, for: SQLRenderer.count(query), table: M.schema.name, operation: "count")
    }

    /// Whether any row matches — honoring grouping, having, and distinct,
    /// which can each empty an otherwise-matching set.
    public func exists<M, R>(_ query: Query<M, R>) async throws -> Bool {
        try await scalar(
            Bool.self, for: SQLRenderer.exists(query), table: M.schema.name, operation: "exists")
    }

    // MARK: Raw statements — the escape hatch

    /// Runs one raw statement, bind-safe by construction.
    ///
    /// The interpolation rules are `SQLFragment`'s: literal text becomes
    /// SQL, interpolated values become bound parameters, and only
    /// `\(raw:)` — which announces itself — can turn a Swift string into
    /// statement text.
    ///
    /// Inside a `transaction { }` this runs on **that transaction's
    /// connection**, which is the whole point: `SET LOCAL`, advisory
    /// locks, and DDL all need connection affinity, and the transaction
    /// repo provides it with no raw connection ever exposed.
    ///
    /// ```swift
    /// try await repo.transaction { tx in
    ///     try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
    ///     try await tx.execute("SELECT pg_advisory_xact_lock(\(42))")
    ///     // ... the actual work ...
    /// }
    /// ```
    ///
    /// Outside a transaction it runs on the primary, like any write. For
    /// row locking, prefer `Query.lockForUpdate()` — typed, discoverable,
    /// and not raw SQL.
    @discardableResult
    public func execute(_ statement: SQLFragment) async throws -> DatabaseRows {
        let rendered = SQLRenderer.statement(statement)
        return try await execute(rendered.postgresQuery(), intent: .write, operation: "execute")
    }

    // MARK: Writes — always explicit; no dirty tracking, no autoflush

    /// Inserts the model and returns it as the database now holds it —
    /// database-generated columns (`@ID(generated: true)`, defaults) are
    /// read back via RETURNING.
    @discardableResult
    public func insert<M: Table>(_ model: M) async throws -> M {
        let returned: [M] = try await rows(
            for: SQLRenderer.insert(model), intent: .write, operation: "insert")
        guard let stored = returned.first else {
            // INSERT... RETURNING yields exactly one row; none means a rule
            // or trigger swallowed the write.
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Inserts every model and returns them as the database now holds them,
    /// in input order. An empty array is a no-op answering `[]`.
    ///
    /// ```swift
    /// let stored = try await repo.insert(rows.map(Event.init))
    /// ```
    ///
    /// Usually one statement — one round trip. A batch whose rows × columns
    /// exceed the 65,535 parameters one statement can bind is split into
    /// several statements inside one transaction (a savepoint when already in
    /// one). Either way it is atomic: all rows or, on any constraint
    /// violation, none. What splitting does change is anything tied to
    /// *statement* boundaries — statement-level triggers and their transition
    /// tables fire once per chunk.
    @discardableResult
    public func insert<M: Table>(_ models: [M]) async throws -> [M] {
        try await insert(models, conflict: nil)
    }

    /// Inserts every model, resolving conflicts as `onConflict` says, and
    /// returns the rows the statement wrote: inserted rows, and rows a
    /// `DO UPDATE` updated. A row skipped by `DO NOTHING` — or by a
    /// `DO UPDATE` whose `updateWhere` rejects it — returns nothing, so the
    /// result can be shorter than `models`; it keeps input order.
    ///
    /// Postgres refuses a statement whose rows conflict with *each other*
    /// under `DO UPDATE` (SQLSTATE 21000, "cannot affect row a second
    /// time"): deduplicate the input first. A batch large enough to be split
    /// keeps that rule — repeated conflict keys are refused before anything
    /// is sent (`HangarError.invalidConflictClause`), because the split
    /// statements would otherwise each update the row and succeed. For the
    /// same reason a split `DO UPDATE` must name its target by columns.
    @discardableResult
    public func insert<M: Table>(_ models: [M], onConflict: OnConflict<M>) async throws -> [M] {
        try await insert(models, conflict: onConflict)
    }

    private func insert<M: Table>(_ models: [M], conflict: OnConflict<M>?) async throws -> [M] {
        guard !models.isEmpty else { return [] }
        // The conflict clause's own binds (index and update predicates) ride
        // in every chunk, so they come off each chunk's budget.
        var probe = BindWriter()
        let reserved = try conflict.map { _ = try SQLRenderer.conflictClause($0, writer: &probe); return probe.binds.count } ?? 0
        let perStatement = Self.rowsPerInsert(columns: M.schema.insertable.count, reserving: reserved)
        guard models.count > perStatement else {
            return try await insertBatch(models, conflict: conflict)
        }
        if let conflict, case .update = conflict.action {
            try Self.refuseRepeatedConflictKeys(models, conflict)
        }
        // More values than one statement can carry. Postgres's protocol counts
        // parameters in a 16-bit field, so a statement binds at most 65,535;
        // past that PostgresNIO refuses before sending. The rows go in chunks
        // that fit, inside one transaction — a savepoint when there already is
        // one — so the batch stays all-or-nothing, as one statement was.
        return try await transaction { tx in
            var stored: [M] = []
            stored.reserveCapacity(models.count)
            var start = models.startIndex
            while start < models.endIndex {
                let end = min(start + perStatement, models.endIndex)
                stored += try await tx.insertBatch(Array(models[start..<end]), conflict: conflict)
                start = end
            }
            return stored
        }
    }

    /// Chunking must not change what an upsert means.
    ///
    /// In one statement, two rows that target the same conflicting row make
    /// Postgres refuse the whole `DO UPDATE` (SQLSTATE 21000, "cannot affect
    /// row a second time"). Split across statements, the second chunk would
    /// quietly update the row again — the same input succeeding or failing
    /// depending only on its size. So before splitting, the conflict keys are
    /// checked for repeats, and a batch that repeats one is refused as the
    /// single statement would have been.
    ///
    /// The check needs the key: a constraint-named target, or a key column
    /// whose Swift type is not `Hashable`, cannot be checked, and such a batch
    /// is refused rather than split on faith. Equality is Swift's — a
    /// case-insensitive collation or `citext` key could still hide a repeat.
    static func refuseRepeatedConflictKeys<M: Table>(_ models: [M], _ conflict: OnConflict<M>) throws {
        guard case .columns(let keyPaths, _) = conflict.target, !keyPaths.isEmpty else {
            throw HangarError.invalidConflictClause(
                table: M.schema.name,
                reason:
                    "DO UPDATE over more rows than one statement can bind is split into several statements, which is only equivalent when no two rows share a conflict key — name the target by its columns so that can be checked, or split the batch yourself")
        }
        var seen = Set<[AnyHashable]>()
        for model in models {
            var key: [AnyHashable] = []
            for keyPath in keyPaths {
                guard let value = model[keyPath: keyPath] as? AnyHashable else {
                    throw HangarError.invalidConflictClause(
                        table: M.schema.name,
                        reason: "a conflict-target column is not Hashable, so repeats across chunks cannot be ruled out — split the batch yourself")
                }
                key.append(value)
            }
            guard seen.insert(key).inserted else {
                throw HangarError.invalidConflictClause(
                    table: M.schema.name,
                    reason:
                        "two rows in the batch share a conflict key; Postgres refuses that within one DO UPDATE (SQLSTATE 21000), and splitting the batch would change the result — deduplicate the input")
            }
        }
    }

    private func insertBatch<M: Table>(_ models: [M], conflict: OnConflict<M>?) async throws -> [M] {
        let returned: [M] = try await rows(
            for: SQLRenderer.insert(models, onConflict: conflict), intent: .write, operation: "insert")
        guard conflict != nil || returned.count == models.count else {
            // A rule or trigger swallowed part of the write.
            throw HangarError.staleModel(table: M.schema.name)
        }
        return returned
    }

    /// The most bind parameters one statement may carry: the protocol's
    /// parameter count is a 16-bit unsigned field.
    static let maximumBindParameters = 65_535

    /// Rows per multi-row `INSERT` so that `rows × columns` stays within
    /// ``maximumBindParameters``.
    static func rowsPerInsert(columns: Int, reserving reserved: Int = 0) -> Int {
        let limit = bindParameterLimitOverride ?? maximumBindParameters
        return max(1, (limit - reserved) / max(1, columns))
    }

    /// Tests only: a smaller limit, so chunking can be exercised with a
    /// handful of rows instead of tens of thousands.
    @TaskLocal static var bindParameterLimitOverride: Int?

    /// Writes every non-key column of the model's row, identified by primary
    /// key, and returns the stored result. Throws `HangarError.staleModel`
    /// if the row no longer exists.
    @discardableResult
    public func update<M: Table>(_ model: M) async throws -> M {
        let returned: [M] = try await rows(
            for: SQLRenderer.update(model), intent: .write, operation: "update")
        guard let stored = returned.first else {
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Deletes the model's row by primary key. Throws
    /// `HangarError.staleModel` if the row no longer exists.
    public func delete<M: Table>(_ model: M) async throws {
        // Soft when the model says so. A `@Deleted` column is a statement
        // that rows are not to be destroyed, and honouring it only when the
        // caller remembers a different method name would make the guarantee
        // worthless — `forceDelete` is the way to mean the other thing.
        if M.isSoftDeletable {
            try await softDelete(model)
            return
        }
        try await forceDelete(model)
    }

    /// Removes the row outright, whether or not the model is soft-deletable.
    ///
    /// The escape hatch for the cases a soft delete cannot serve: an erasure
    /// request, a bad import, a test tearing down its fixtures.
    public func forceDelete<M: Table>(_ model: M) async throws {
        let statement = try SQLRenderer.delete(model)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .write, operation: "delete")
        var deleted = 0
        for try await _ in sequence { deleted += 1 }
        guard deleted > 0 else {
            throw HangarError.staleModel(table: M.schema.name)
        }
    }

    /// Stamps the model's `@Deleted` column, leaving the row in place.
    ///
    /// Throws ``HangarError/staleModel(table:)`` when nothing was stamped —
    /// the row is gone, or was already deleted. Deleting twice is a fact
    /// worth surfacing rather than a silent overwrite of the timestamp.
    public func softDelete<M: Table>(_ model: M, at instant: Date = Date()) async throws {
        let statement = try SQLRenderer.softDelete(model, at: instant)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .write, operation: "soft_delete")
        var affected = 0
        for try await _ in sequence { affected += 1 }
        guard affected > 0 else {
            throw HangarError.staleModel(table: M.schema.name)
        }
    }

    /// Clears the model's `@Deleted` column, bringing the row back.
    ///
    /// Throws ``HangarError/staleModel(table:)`` when nothing was restored —
    /// no such row, or it was not deleted to begin with.
    public func restore<M: Table>(_ model: M) async throws {
        let statement = try SQLRenderer.restore(model)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .write, operation: "restore")
        var affected = 0
        for try await _ in sequence { affected += 1 }
        guard affected > 0 else {
            throw HangarError.staleModel(table: M.schema.name)
        }
    }

    /// Writes the same values to every row the query's predicate matches,
    /// in one statement. Returns how many rows were written — zero is a
    /// normal answer, not an error.
    ///
    /// ```swift
    /// let published = try await repo.update(Post.where { $0.published == false }) {
    ///     ($0.published.set(to: true), $0.reviewedAt.set(to: Date()))
    /// }
    /// ```
    ///
    /// Assignments are typed against their columns, so assigning the wrong
    /// type is a compile error; values are always bound parameters. For
    /// per-row values, fetch and write row by row — this writes one value
    /// set to the whole match.
    ///
    /// - Throws: ``HangarError/bulkWriteClause(table:operation:clause:)``
    ///   if the query carries a clause UPDATE cannot honor;
    ///   ``HangarError/noUpdatableColumns(table:)`` for an empty SET.
    @discardableResult
    public func update<M: Table, R, each A: Assignable>(
        _ query: Query<M, R>,
        set build: (M.QueryColumns) -> (repeat each A)
    ) async throws -> Int {
        let built = build(M.queryColumns)
        var assignments: [ColumnAssignment] = []
        for assignment in repeat each built {
            assignments.append(assignment._assignment)
        }
        let statement = try SQLRenderer.update(query, set: assignments)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .write, operation: "update")
        var updated = 0
        for try await _ in sequence { updated += 1 }
        return updated
    }

    /// Deletes every row the query's predicate matches, in one statement.
    /// Returns how many were deleted — zero is a normal answer, not an
    /// error, because "nothing matched" is a legitimate outcome for a
    /// predicate in a way it is not for a specific model's primary key.
    ///
    /// ```swift
    /// let purged = try await repo.delete(Session.where { $0.expiresAt < .now })
    /// ```
    ///
    /// A query with no predicate deletes **every row in the table** — that
    /// is what `Session.all` means, and it is honored, not second-guessed.
    ///
    /// - Throws: ``HangarError/bulkWriteClause(table:operation:clause:)``
    ///   if the query carries LIMIT, OFFSET, ORDER BY, GROUP BY, HAVING, or
    ///   DISTINCT — DELETE cannot honor them, and dropping them silently
    ///   would delete rows you did not ask it to.
    @discardableResult
    public func delete<M: Table, R>(_ query: Query<M, R>) async throws -> Int {
        let statement = try SQLRenderer.delete(query)
        let sequence = try await execute(
            statement.postgresQuery(), intent: .write, operation: "delete")
        var deleted = 0
        for try await _ in sequence { deleted += 1 }
        return deleted
    }

    // MARK: Changeset writes — minimal, validated

    /// Inserts a validated changeset: only its changed fields appear in the
    /// INSERT; every other column falls to its database default. Throws
    /// `ChangesetValidationError` (from `validatedChanges`) before
    /// anything reaches the wire if the changeset is invalid.
    @discardableResult
    public func insert<M: Table>(_ changeset: Changeset<M>) async throws -> M {
        let validated = try changeset.validatedChanges()
        let returned: [M] = try await rows(
            for: SQLRenderer.insert(validated, into: M.self), intent: .write, operation: "insert")
        guard let stored = returned.first else {
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Upsert: insert with `ON CONFLICT` behavior. With
    /// `.doUpdate`, the conflicting row is updated (only the `set` columns,
    /// from the incoming values) and returned. With `.doNothing`, a
    /// conflicting insert is skipped and the result is nil.
    @discardableResult
    public func insert<M: Table>(
        _ changeset: Changeset<M>, onConflict: OnConflict<M>
    ) async throws -> M? {
        let validated = try changeset.validatedChanges()
        let returned: [M] = try await rows(
            for: SQLRenderer.insert(validated, into: M.self, onConflict: onConflict),
            intent: .write, operation: "insert")
        return returned.first
    }

    /// Updates only the changeset's changed fields, addressed by the
    /// original's primary key — this is where dirty tracking pays off: an
    /// untouched column never appears in the SET clause. A changeset with
    /// no changes is a no-op and returns the original without a query.
    @discardableResult
    public func update<M: Table>(_ changeset: Changeset<M>) async throws -> M {
        let validated = try changeset.validatedChanges()
        guard validated.identity != nil else {
            throw HangarError.updateWithoutIdentity(table: M.schema.name)
        }
        if validated.changedFields.isEmpty, let original = changeset.original {
            return original
        }
        let returned: [M] = try await rows(
            for: SQLRenderer.update(validated, into: M.self), intent: .write, operation: "update")
        guard let stored = returned.first else {
            // An optimistically-locked write that matched nothing is a lost
            // update far more often than a deleted row, and the two are not
            // distinguishable without a second query — so the error names
            // the guard that failed instead of asserting the row is gone.
            // `staleModel`'s message ("no longer exists — it was deleted
            // concurrently or never inserted") sent applications to 404 for
            // what is a 409, and `ValidatedChanges.lock` was sitting right
            // here saying which column guarded the statement.
            if let lock = validated.lock {
                throw ChangesetConflictError(
                    table: validated.tableName,
                    field: lock.field,
                    expected: String(describing: lock.expected))
            }
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    // MARK: Execution

    /// PostgresNIO's "logging disabled" for entry points that require a
    /// logger (`PostgresConnection.query`), matching what `nil` means on
    /// `PostgresClient`.
    static let quietLogger = Logger(
        label: "hangar.quiet", factory: { _ in SwiftLogNoOpLogHandler() })

    /// The one funnel to the wire: pooled client normally (routed by
    /// `intent` when a replica is configured), the transaction's own
    /// connection inside `transaction { }` — which is what makes a read
    /// inside a transaction see that transaction's uncommitted writes.
    ///
    /// Instrumentation lives here so every statement gets it:
    /// a debug log line with the SQL (placeholders only — values are binds
    /// and never appear), and a `hangar.query.duration` timer dimensioned
    /// by operation. The measured duration is dispatch-to-first-response;
    /// consuming a large result set costs extra and is not included.
    func execute(
        _ query: PostgresQuery, intent: Intent, operation: String
    ) async throws -> DatabaseRows {
        let start = ContinuousClock.now
        let sequence: PostgresRowSequence
        do {
            switch backend {
            case .client(let primary, let replica):
                let client = intent == .read ? (replica ?? primary) : primary
                sequence = try await client.query(query, logger: logger)
            case .transaction(let connection, _):
                sequence = try await connection.query(query, logger: logger ?? Self.quietLogger)
            }
        } catch {
            throw failed(error, sql: query.sql, operation: operation)
        }
        let duration = ContinuousClock.now - start
        // Constructed per statement rather than cached per operation on
        // purpose. Caching was tried: `Timer(label:dimensions:)` binds to
        // whatever factory `MetricsSystem` held when the cache was first
        // touched, so a process that bootstraps its backend after issuing a
        // query — which the metrics test does, and which a library cannot
        // prevent — would then record into the no-op backend forever, with
        // nothing to see. Swapping a robustness property for an unmeasured
        // allocation is the wrong trade for a package that argues from
        // benchmarks; if this ever shows up in one, cache it then.
        Timer(
            label: "hangar.query.duration",
            dimensions: [("operation", operation)],
            preferredDisplayUnit: .milliseconds
        ).recordNanoseconds(nanoseconds(of: duration))
        reportDiagnostics(sql: query.sql, operation: operation, duration: duration)
        logger?.debug(
            "hangar query",
            metadata: [
                "sql": .string(query.sql),
                "operation": .string(operation),
                "duration_ms": .stringConvertible(Double(nanoseconds(of: duration)) / 1e6),
            ])
        let sql = query.sql
        return DatabaseRows(base: sequence) { [self] error in
            failed(error, sql: sql, operation: operation)
        }
    }

    /// Everything that happens to a failed statement, in one place: server
    /// errors become ``DatabaseError``, a failure inside a transaction is
    /// recorded so the transaction can say why Postgres aborted it, and the
    /// failure is reported once. Returns the error to throw.
    func failed(_ error: any Error, sql: String, operation: String) -> any Error {
        let translated = translatingDatabaseErrors(error)
        if let database = translated as? DatabaseError, case .transaction(_, let depth) = backend {
            transactionLedger?.record(database, depth: depth)
        }
        reportFailure(translated, sql: sql, operation: operation)
        return translated
    }

    /// Says why a statement failed, once, where the statement is known.
    ///
    /// PostgresNIO redacts `PSQLError.description` on purpose — it can carry
    /// bound parameters — so an error that reaches an application's own log
    /// arrives as "Generic description to prevent accidental leakage of
    /// sensitive data. For debugging details, use `String(reflecting:
    /// error)`", and a 500 caused by a missing table, a constraint, or a
    /// serialization failure was indistinguishable from any other 500. The
    /// server's own diagnostic fields carry no binds, and a SQLSTATE is the
    /// difference between "retry this" and "page someone".
    ///
    /// Through the diagnostics logger, so it is not lost on a repo built
    /// without one — which is every repo `withRepo` constructs.
    ///
    /// Metadata only: SQLSTATE, kind, table, constraint and column *names*,
    /// with the SQL as sent (placeholders, never values). The server's text
    /// is left out — its detail quotes rows (`Key (email)=(ada@…)`), and its
    /// primary message can too (`invalid input syntax for type integer:
    /// "<the value>"`), as can a trigger's `RAISE` — while an error-level line
    /// reaches every log sink an application has. It is all still on
    /// ``DatabaseError/message`` and ``DatabaseError/underlying`` for code
    /// that wants it on purpose.
    private func reportFailure(_ error: any Error, sql: String, operation: String) {
        guard let database = error as? DatabaseError else { return }
        var metadata: Logger.Metadata = [
            "sql": .string(sql),
            "operation": .string(operation),
            "sqlstate": .string(database.sqlState),
            "kind": .string(database.kindName),
        ]
        if let table = database.table { metadata["table"] = .string(table) }
        if let constraint = database.constraint { metadata["constraint"] = .string(constraint) }
        if !database.columns.isEmpty {
            metadata["columns"] = .array(database.columns.map { .string($0) })
        }
        diagnosticsLogger.error("hangar statement failed", metadata: metadata)
    }

    private func nanoseconds(of duration: Duration) -> Int64 {
        Int64(duration.components.seconds &* 1_000_000_000)
            &+ Int64(duration.components.attoseconds / 1_000_000_000)
    }

    private func rows<R: RowDecodable>(
        for statement: RenderedStatement, intent: Intent, operation: String
    ) async throws -> [R] {
        let sequence = try await execute(
            statement.postgresQuery(), intent: intent, operation: operation)
        var results: [R] = []
        for try await row in sequence {
            results.append(try R(from: row))
        }
        return results
    }

    private func scalar<V: PostgresDecodable>(
        _ type: V.Type, for statement: RenderedStatement, table: String, operation: String
    ) async throws -> V {
        let sequence = try await execute(
            statement.postgresQuery(), intent: .read, operation: operation)
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(V.self, from: cells[0], table: table, column: "?column?")
        }
        throw HangarError.columnCountMismatch(table: table, expected: 1, got: 0)
    }
}

// MARK: - Ambient access

extension Repo {
    /// Binds `Repo.current` for the duration of `body` — Hangar owns the
    /// task-local; whoever manages lifetime populates it (a standalone user
    /// directly, Alula's adapter when opening a request scope).
    public static func with<T>(
        _ repo: Repo,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(repo) {
            try await body()
        }
    }

    /// The ambient repo, or a clear error naming the problem. Task-locals
    /// propagate to structured child tasks (`async let`, task groups) but
    /// **not** across `Task.detached` — and that is correct: a background
    /// job should not silently join a request's transaction.
    public static func require() throws -> Repo {
        guard let repo = current else {
            throw HangarError.noAmbientRepo
        }
        return repo
    }
}

extension Repo {
    @TaskLocal public static var current: Repo?
}
