/// Upsert behavior for `repo.insert(changeset, onConflict:)`
/// — first-class rather than raw SQL, because `ON CONFLICT` is used
/// constantly and is painful to express through an escape hatch.
///
/// ```swift
/// try await repo.insert(changeset, onConflict:.doUpdate(
///     target: [\Post.slug],
///     set: [\Post.title, \Post.body]))
/// try await repo.insert(changeset, onConflict:.doNothing)
/// ```
///
/// Keypaths resolve to column names through the entity's TableModel
/// metadata at render time; a keypath that isn't a column throws before
/// anything reaches the wire.
public struct OnConflict<M: Table>: Sendable {
    enum Action: Sendable {
        case nothing
        /// `DO UPDATE SET col = EXCLUDED.col,...`
        case update([PartialKeyPath<M> & Sendable])
    }

    /// The conflict target columns — the unique index the conflict is
    /// detected on. Empty only for `.doNothing`, where Postgres allows an
    /// unqualified `ON CONFLICT DO NOTHING`.
    let target: [PartialKeyPath<M> & Sendable]
    let action: Action

    /// `ON CONFLICT DO NOTHING`: a conflicting insert is silently skipped
    /// and `insert` returns nil.
    public static var doNothing: OnConflict {
        OnConflict(target: [], action: .nothing)
    }

    /// `ON CONFLICT (target) DO NOTHING` — scoped to one unique index.
    public static func doNothing(target: [PartialKeyPath<M> & Sendable]) -> OnConflict {
        OnConflict(target: target, action: .nothing)
    }

    /// `ON CONFLICT (target) DO UPDATE SET set... = EXCLUDED...` — the
    /// conflicting row is updated with the incoming values of the `set`
    /// columns, and `insert` returns the stored result.
    public static func doUpdate(
        target: [PartialKeyPath<M> & Sendable],
        set: [PartialKeyPath<M> & Sendable]
    ) -> OnConflict {
        OnConflict(target: target, action: .update(set))
    }
}

extension SQLRenderer {
    /// The `ON CONFLICT...` clause, or a thrown error for keypaths that
    /// aren't columns.
    static func conflictClause<M: Table>(_ conflict: OnConflict<M>) throws -> String {
        func columns(_ keyPaths: [PartialKeyPath<M> & Sendable]) throws -> [String] {
            try keyPaths.map { keyPath in
                guard let name = M.columnName(for: keyPath) else {
                    throw HangarError.unknownColumn(table: M.schema.name, column: "\(keyPath)")
                }
                return name
            }
        }
        let target = try columns(conflict.target)
        let targetClause =
            target.isEmpty
            ? "" : " (\(target.map(quote).joined(separator: ", ")))"
        switch conflict.action {
        case .nothing:
            return "ON CONFLICT\(targetClause) DO NOTHING"
        case .update(let set):
            let assignments = try columns(set)
                .map { "\(quote($0)) = EXCLUDED.\(quote($0))" }
                .joined(separator: ", ")
            return "ON CONFLICT\(targetClause) DO UPDATE SET \(assignments)"
        }
    }
}
