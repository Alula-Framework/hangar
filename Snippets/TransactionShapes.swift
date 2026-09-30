// The README's transaction, bulk-write and upsert examples, and the
// HGR-QUERY-4115 page's rolled-back EXPLAIN ANALYZE, as code the build
// compiles.
//
// A README that shows an API is a claim about that API. These are the shapes
// the README's Transactions, Row locks, Bulk writes and Upserts paragraphs
// use — and the ones the TransactionsAndConnections article and the
// `OnConflict` documentation show — so a signature change there breaks the
// build here rather than only misleading a reader.
import Foundation
import Hangar

// snippet.hide
@Entity("hangar_orders")
struct SnippetOrder: Sendable {
    @ID var id: UUID
    var label: String
}

@Entity("hangar_line_items")
struct SnippetLineItem: Sendable {
    @ID var id: UUID
    @Column("order_id") var orderID: UUID
    var quantity: Int
}

@Entity("hangar_accounts")
struct SnippetAccount: Sendable {
    @ID var id: UUID
    var balance: Int
}

@Entity("hangar_users")
struct SnippetUser: Sendable {
    @ID var id: UUID
    var email: String
    var name: String
    @Column("deleted_at") var deletedAt: Date?
}

@Entity("hangar_docs")
struct SnippetDoc: Sendable {
    @ID var id: UUID
    var body: String
    var version: Int
}

@Entity("hangar_sessions")
struct SnippetSession: Sendable {
    @ID var id: UUID
    @Column("expires_at") var expiresAt: Date
    var version: Int
    @Column("updated_at") var updatedAt: Date
}

@Entity("hangar_events")
struct SnippetEvent: Sendable {
    @ID var id: UUID
    var name: String
}
// snippet.show

func transactionShapes(
    repo: Repo, order: SnippetOrder, lineItem: SnippetLineItem, extra: SnippetLineItem, accountID: UUID
) async throws {
    // Retrying a SERIALIZABLE transaction: 3 is the total number of attempts.
    // The nested call is a SAVEPOINT; isolation belongs to the outermost BEGIN.
    try await repo.transaction(isolation: .serializable, retryingOnSerializationFailure: 3) { tx in
        try await tx.insert(order)
        // `transaction` returns the body's value — here the inserted row —
        // and is @discardableResult, so the README's shape needs no `_ =`.
        try await tx.transaction { inner in  // SAVEPOINT
            try await inner.insert(lineItem)
        }
    }

    // A failure caught at a savepoint leaves the outer transaction healthy.
    try await repo.transaction { tx in
        try await tx.insert(order)
        do {
            try await tx.transaction { inner in  // SAVEPOINT
                try await inner.insert(extra)
            }
        } catch {
            // The savepoint rolled back. The order is still there.
        }
    }

    // Isolation alone, and a server-enforced bound on every statement.
    try await repo.transaction(isolation: .repeatableRead, statementTimeout: .seconds(5)) { tx in
        _ = try await tx.all(SnippetOrder.all)
    }

    // Raw statements and row locks on the transaction's own connection.
    try await repo.transaction { tx in
        try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
        try await tx.execute("SELECT pg_advisory_xact_lock(\(42))")
        _ = try await tx.one(SnippetAccount.where { $0.id == accountID }.lockForUpdate())
    }

    // Rolling back on purpose, carrying a value out.
    do {
        try await repo.transaction { tx in
            try await tx.insert(order)
            throw RollbackError.intentional("dry run")
        }
    } catch RollbackError.intentional(let reason) {
        _ = reason
    }

    // Typed server errors.
    do {
        try await repo.insert(order)
    } catch let error as DatabaseError where error.isUniqueViolation {
        _ = (error.constraint, error.columnName)
    }
}

func bulkAndUpsertShapes(repo: Repo, names: [String], users: [SnippetUser], docs: [SnippetDoc]) async throws {
    // Bulk writes: one multi-row INSERT (split, atomically, past 65,535 binds),
    // and single-statement DELETE and UPDATE over a predicate.
    _ = try await repo.insert(names.map { SnippetEvent(id: UUID(), name: $0) })
    _ = try await repo.delete(SnippetSession.where { $0.expiresAt < .now })
    _ = try await repo.update(SnippetDoc.where { $0.version == 0 }) {
        ($0.body.set(to: ""), $0.version.set(to: $0.version.adding(1)))
    }
    _ = try await repo.update(SnippetSession.where { $0.id == UUID() }) {
        ($0.version.set(to: $0.version.adding(1)),  // SET version = (version + $1)
         $0.updatedAt.set(to: .transactionTimestamp))  // the server's now()
    }

    // Upserts, by columns, a partial unique index, or a constraint name.
    try await repo.insert(users, onConflict: .doNothing)
    try await repo.insert(users, onConflict: .doNothing(target: [\SnippetUser.email]))
    try await repo.insert(
        users, onConflict: .doNothing(target: [\SnippetUser.email], where: { $0.deletedAt == nil }))
    try await repo.insert(
        users, onConflict: .doUpdate(target: [\SnippetUser.email], set: [\SnippetUser.name]))
    try await repo.insert(
        users, onConflict: .doUpdate(constraint: "hangar_users_email_key", set: [\SnippetUser.name]))

    // A conditional DO UPDATE: `existing` is the stored row, `incoming` is
    // Postgres's EXCLUDED.
    try await repo.insert(
        docs,
        onConflict: .doUpdate(
            target: [\SnippetDoc.id], set: [\SnippetDoc.body, \SnippetDoc.version],
            updateWhere: { existing, incoming in existing.version < incoming.version }))

    // The changeset form answers the stored row, or nil when nothing was written.
    let changeset = Changeset(SnippetUser.self)
        .change(\.email, "ada@example.com")
        .change(\.name, "Ada")
    _ = try await repo.insert(
        changeset, onConflict: .doUpdate(target: [\SnippetUser.email], set: [\SnippetUser.name]))
    _ = try await repo.insert(changeset, onConflict: .doNothing)
}

func explainWriteShape(repo: Repo, cutoff: Date) async throws {
    // HGR-QUERY-4115's page: measure a write with EXPLAIN ANALYZE inside a
    // transaction that rolls it back.
    do {
        try await repo.transaction { tx in
            let rows = try await tx.execute(
                "EXPLAIN (ANALYZE, BUFFERS) DELETE FROM \(raw: "orders") WHERE placed_at < \(cutoff)")
            var plan: [String] = []
            for try await line in rows.decode(String.self) { plan.append(line) }
            throw RollbackError.intentional(plan.joined(separator: "\n"))
        }
    } catch RollbackError.intentional(let plan) {
        print(plan)  // the DELETE ran, and was rolled back
    }
}
