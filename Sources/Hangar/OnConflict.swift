/// Upsert behavior for `repo.insert(changeset, onConflict:)` and
/// `repo.insert(models, onConflict:)` — first-class rather than raw SQL,
/// because `ON CONFLICT` is used constantly and is painful to express through
/// an escape hatch.
///
/// ```swift
/// try await repo.insert(changeset, onConflict: .doUpdate(
///     target: [\Post.slug],
///     set: [\Post.title, \Post.body]))
/// try await repo.insert(changeset, onConflict: .doNothing)
/// ```
///
/// The conflict can be named three ways:
///
/// - **Columns** — `target: [\User.email]` — the unique index Postgres infers
///   from them.
/// - **Columns of a partial unique index** — add `where:` with the index's
///   predicate, e.g. `where: { $0.deletedAt == nil }` for an index on email
///   among live rows. Without it Postgres finds no matching index and fails
///   with SQLSTATE 42P10.
/// - **A constraint by name** — `constraint: "users_email_key"`.
///
/// `DO UPDATE` can be made conditional with `updateWhere:`, which sees the
/// existing row and the incoming one (Postgres's `EXCLUDED`):
///
/// ```swift
/// .doUpdate(target: [\Doc.id], set: [\Doc.body, \Doc.version],
///           updateWhere: { existing, incoming in existing.version < incoming.version })
/// ```
///
/// A row the condition rejects is left as it is and, like a `DO NOTHING`
/// conflict, returns nothing.
///
/// Keypaths resolve to column names through the entity's TableModel metadata
/// at render time. A keypath that isn't a column, a `DO UPDATE` without a
/// target (Postgres rejects it: "ON CONFLICT DO UPDATE requires inference
/// specification or constraint name"), or one with nothing to set, throws
/// before anything reaches the wire.
public struct OnConflict<M: Table>: Sendable {
    enum Target: Sendable {
        case none
        case columns([PartialKeyPath<M> & Sendable], indexPredicate: Predicate?)
        case constraint(String)
    }

    enum Action: Sendable {
        case nothing
        /// `DO UPDATE SET col = EXCLUDED.col, … [WHERE …]`
        case update([PartialKeyPath<M> & Sendable], condition: Predicate?)
    }

    let target: Target
    let action: Action

    /// `ON CONFLICT DO NOTHING`: a conflicting insert is silently skipped
    /// and returns nothing.
    public static var doNothing: OnConflict {
        OnConflict(target: .none, action: .nothing)
    }

    /// `ON CONFLICT (target) DO NOTHING` — scoped to one unique index.
    public static func doNothing(target: [PartialKeyPath<M> & Sendable]) -> OnConflict {
        OnConflict(target: .columns(target, indexPredicate: nil), action: .nothing)
    }

    /// `ON CONFLICT (target) WHERE predicate DO NOTHING` — a partial unique
    /// index, named by its columns and predicate.
    public static func doNothing(
        target: [PartialKeyPath<M> & Sendable],
        where indexPredicate: (M.QueryColumns) -> some PredicateConvertible
    ) -> OnConflict {
        OnConflict(
            target: .columns(target, indexPredicate: indexPredicate(M.queryColumns).predicate),
            action: .nothing)
    }

    /// `ON CONFLICT ON CONSTRAINT "name" DO NOTHING`.
    public static func doNothing(constraint: String) -> OnConflict {
        OnConflict(target: .constraint(constraint), action: .nothing)
    }

    /// `ON CONFLICT (target) DO UPDATE SET set… = EXCLUDED…` — the
    /// conflicting row is updated with the incoming values of the `set`
    /// columns, and the stored result is returned.
    public static func doUpdate(
        target: [PartialKeyPath<M> & Sendable],
        set: [PartialKeyPath<M> & Sendable]
    ) -> OnConflict {
        OnConflict(target: .columns(target, indexPredicate: nil), action: .update(set, condition: nil))
    }

    /// `DO UPDATE` against a unique index (optionally partial, via `where:`),
    /// applied only where `updateWhere` holds.
    public static func doUpdate(
        target: [PartialKeyPath<M> & Sendable],
        where indexPredicate: ((M.QueryColumns) -> Predicate)? = nil,
        set: [PartialKeyPath<M> & Sendable],
        updateWhere: ((_ existing: M.QueryColumns, _ incoming: M.QueryColumns) -> Predicate)? = nil
    ) -> OnConflict {
        OnConflict(
            target: .columns(target, indexPredicate: indexPredicate?(M.queryColumns)),
            action: .update(set, condition: updateWhere.map(condition)))
    }

    /// `ON CONFLICT ON CONSTRAINT "name" DO UPDATE SET …`, applied only where
    /// `updateWhere` holds.
    public static func doUpdate(
        constraint: String,
        set: [PartialKeyPath<M> & Sendable],
        updateWhere: ((_ existing: M.QueryColumns, _ incoming: M.QueryColumns) -> Predicate)? = nil
    ) -> OnConflict {
        OnConflict(target: .constraint(constraint), action: .update(set, condition: updateWhere.map(condition)))
    }

    /// The existing row qualifies with the table's name, the incoming row
    /// with Postgres's `EXCLUDED` pseudo-table.
    private static func condition(
        _ build: (M.QueryColumns, M.QueryColumns) -> Predicate
    ) -> Predicate {
        build(M.QueryColumns(table: M.schema.name), M.QueryColumns(table: "excluded"))
    }
}

extension SQLRenderer {
    /// The `ON CONFLICT…` clause, or a thrown error for a clause Postgres
    /// would reject or a keypath that isn't a column.
    static func conflictClause<M: Table>(_ conflict: OnConflict<M>, writer: inout BindWriter) throws -> String {
        func columns(_ keyPaths: [PartialKeyPath<M> & Sendable]) throws -> [String] {
            try keyPaths.map { keyPath in
                guard let name = M.columnName(for: keyPath) else {
                    throw HangarError.unknownColumn(table: M.schema.name, column: "\(keyPath)")
                }
                return name
            }
        }
        var clause = "ON CONFLICT"
        switch conflict.target {
        case .none:
            break
        case .columns(let keyPaths, let indexPredicate):
            let names = try columns(keyPaths)
            if !names.isEmpty {
                clause += " (\(names.map(quote).joined(separator: ", ")))"
            } else if indexPredicate != nil {
                throw HangarError.invalidConflictClause(
                    table: M.schema.name, reason: "an index predicate needs the index's columns")
            }
            if let indexPredicate {
                // Bare column names: the predicate names the index, whose
                // columns belong to the target table alone.
                let wasQualified = writer.qualified
                writer.qualified = false
                clause += " WHERE \(render(indexPredicate.expression, writer: &writer))"
                writer.qualified = wasQualified
            }
        case .constraint(let name):
            guard !name.isEmpty else {
                throw HangarError.invalidConflictClause(table: M.schema.name, reason: "the constraint name is empty")
            }
            clause += " ON CONSTRAINT \(quote(name))"
        }
        switch conflict.action {
        case .nothing:
            return clause + " DO NOTHING"
        case .update(let set, let condition):
            if case .none = conflict.target {
                throw HangarError.invalidConflictClause(
                    table: M.schema.name,
                    reason: "DO UPDATE needs a target — the conflicting columns or a constraint name")
            }
            if case .columns(let keyPaths, _) = conflict.target, keyPaths.isEmpty {
                throw HangarError.invalidConflictClause(
                    table: M.schema.name,
                    reason: "DO UPDATE needs a target — the conflicting columns or a constraint name")
            }
            let names = try columns(set)
            guard !names.isEmpty else {
                throw HangarError.invalidConflictClause(table: M.schema.name, reason: "DO UPDATE has no columns to set")
            }
            clause += " DO UPDATE SET " + names.map { "\(quote($0)) = EXCLUDED.\(quote($0))" }.joined(separator: ", ")
            if let condition {
                // Qualified: the condition compares the existing row with
                // EXCLUDED, and bare names would be ambiguous between them.
                let wasQualified = writer.qualified
                writer.qualified = true
                clause += " WHERE \(render(condition.expression, writer: &writer))"
                writer.qualified = wasQualified
            }
            return clause
        }
    }
}
