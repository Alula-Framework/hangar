import Changesets
import PostgresNIO

// Preloading: always batched, never joined. For N parents,
// each association costs exactly one extra query — `WHERE fk = ANY($1)` —
// then rows are grouped in memory and assigned into each parent's
// `Loadable`. Two has-many preloads never multiply into a cartesian
// product, which is why separate queries are the default.
//
// The underscored loader types and factories are referenced by
// `@Entity`-generated `_association(for:)` implementations — public for
// that reason only, not user API. Each factory captures the association's
// key type inside closures, so the registry can stay untyped over keys
// while parents/children remain fully typed.

/// A key type usable for batching: bindable alone and as an array, and
/// hashable for in-memory grouping.
public typealias PreloadKey = ColumnCodable & Hashable & PostgresArrayEncodable

// MARK: - Loaders (one per association shape)

/// Generated-registry loader for `@HasMany` — public only for the
/// macro's expansion, not user API.
public struct _HasManyLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run:
        @Sendable (
            _ parents: inout [Parent],
            _ repo: Repo,
            _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
        ) async throws -> Void
}

/// The loader behind `@HasMany(through:from:to:)` — deliberately not
/// parameterized on the join table, so `.preload` call sites dispatch on
/// exactly the types they can see.
public struct _HasManyThroughLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run:
        @Sendable (
            _ parents: inout [Parent],
            _ repo: Repo,
            _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
        ) async throws -> Void
}

/// `@BelongsTo` with a non-optional foreign key: every parent must find its
/// row; a dangling reference throws rather than lying with `.notLoaded`.
public struct _ToOneLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run:
        @Sendable (
            _ parents: inout [Parent],
            _ repo: Repo,
            _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
        ) async throws -> Void
}

/// `@HasOne`, or `@BelongsTo` over an optional foreign key: absence is
/// data, expressed as `.loaded(nil)` — distinct from `.notLoaded`.
public struct _OptionalToOneLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run:
        @Sendable (
            _ parents: inout [Parent],
            _ repo: Repo,
            _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
        ) async throws -> Void
}

// MARK: - Factories (called from @Entity-generated metadata)

/// Factory for `@HasMany`'s generated registry entry — one batched
/// `= ANY($1)` query, grouped in memory by foreign key.
public func _hasMany<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    parentKey: KeyPath<Parent, Key> & Sendable,
    foreignKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<[Child]>> & Sendable
) -> _HasManyLoader<Parent, Child> {
    _HasManyLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let children = try await repo.all(
            filtered(tune(Child.all), by: foreignKey, in: keys, association: name))
        let grouped = Dictionary(grouping: children) { $0[keyPath: foreignKey] }
        for index in parents.indices {
            let key = parents[index][keyPath: parentKey]
            parents[index][keyPath: target] = .loaded(grouped[key] ?? [])
        }
    }
}

/// Factory for `@HasMany` over a **nullable** foreign key — the child
/// column may be NULL, meaning "belongs to no parent". Those children
/// simply appear under no parent; the query still binds non-null parent
/// keys, so `= ANY($1)` never has to reason about NULL.
///
/// Selected by ordinary overload resolution: the generated registry entry
/// is identical either way, and the keypath's type decides which factory it
/// lands on.
public func _hasMany<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    parentKey: KeyPath<Parent, Key> & Sendable,
    foreignKey: KeyPath<Child, Key?> & Sendable,
    target: WritableKeyPath<Parent, Loadable<[Child]>> & Sendable
) -> _HasManyLoader<Parent, Child> {
    _HasManyLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let children = try await repo.all(
            filtered(tune(Child.all), by: foreignKey, in: keys, association: name))
        let grouped = Dictionary(grouping: children) { $0[keyPath: foreignKey] }
        for index in parents.indices {
            let key = parents[index][keyPath: parentKey]
            parents[index][keyPath: target] = .loaded(grouped[key] ?? [])
        }
    }
}

/// Factory for `@BelongsTo`'s generated registry entry. A non-nil
/// foreign key that matches no row throws `danglingBelongsTo`.
public func _belongsTo<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    foreignKey: KeyPath<Parent, Key> & Sendable,
    references relatedKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child>> & Sendable
) -> _ToOneLoader<Parent, Child> {
    _ToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: foreignKey] }))
        let related = try await repo.all(
            filtered(tune(Child.all), by: relatedKey, in: keys, association: name))
        // First row per key wins. NOT `Dictionary(uniqueKeysWithValues:)`:
        // that traps on a duplicate, and a `references:` pointed at a
        // non-unique column is a user mistake, not a Hangar invariant —
        // the rule is: fail the request, never the node.
        let indexed = Dictionary(related.map { ($0[keyPath: relatedKey], $0) }) { first, _ in first
        }
        for index in parents.indices {
            guard let child = indexed[parents[index][keyPath: foreignKey]] else {
                throw HangarError.danglingBelongsTo(table: Parent.schema.name, association: name)
            }
            parents[index][keyPath: target] = .loaded(child)
        }
    }
}

/// `@BelongsTo` over a nullable foreign key: parents with a nil key load
/// `.loaded(nil)` without ever querying for them.
public func _belongsTo<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    foreignKey: KeyPath<Parent, Key?> & Sendable,
    references relatedKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child?>> & Sendable
) -> _OptionalToOneLoader<Parent, Child> {
    _OptionalToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.compactMap { $0[keyPath: foreignKey] }))
        let related =
            keys.isEmpty
            ? []
            : try await repo.all(
                filtered(tune(Child.all), by: relatedKey, in: keys, association: name))
        // First row per key wins — see the non-optional overload above.
        let indexed = Dictionary(related.map { ($0[keyPath: relatedKey], $0) }) { first, _ in first
        }
        for index in parents.indices {
            guard let key = parents[index][keyPath: foreignKey] else {
                parents[index][keyPath: target] = .loaded(nil)
                continue
            }
            guard let child = indexed[key] else {
                throw HangarError.danglingBelongsTo(table: Parent.schema.name, association: name)
            }
            parents[index][keyPath: target] = .loaded(child)
        }
    }
}

/// Factory for `@HasOne`'s generated registry entry — `.loaded(nil)`
/// means "no related row", which is data, not an error.
public func _hasOne<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    parentKey: KeyPath<Parent, Key> & Sendable,
    foreignKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child?>> & Sendable
) -> _OptionalToOneLoader<Parent, Child> {
    _OptionalToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let children = try await repo.all(
            filtered(tune(Child.all), by: foreignKey, in: keys, association: name))
        // First row per key wins; a schema that allows several is a
        // has-many wearing the wrong attribute.
        var indexed: [Key: Child] = [:]
        for child in children where indexed[child[keyPath: foreignKey]] == nil {
            indexed[child[keyPath: foreignKey]] = child
        }
        for index in parents.indices {
            parents[index][keyPath: target] = .loaded(indexed[parents[index][keyPath: parentKey]])
        }
    }
}

/// ANDs `column = ANY($keys)` onto the (possibly user-tuned) child query.
/// The column name resolves at runtime through the child's TableModel
/// metadata — the one piece of cross-type information the macro cannot see
/// at expansion time.
private func filtered<Child: Table, Key: PreloadKey>(
    _ query: Query<Child, Child>,
    by keyPath: AnyKeyPath,
    in keys: [Key],
    association: String
) throws -> Query<Child, Child> {
    guard let column = Child.columnName(for: keyPath) else {
        throw HangarError.unknownAssociation(table: Child.schema.name, association: association)
    }
    let membership = SQLExpression.anyOf(
        .column(table: Child.schema.name, name: column),
        .bind(SQLBind { try $0.append(keys) }))
    var next = query
    if let existing = next.predicate {
        next.predicate = Predicate(expression: .infix("AND", existing.expression, membership))
    } else {
        next.predicate = Predicate(expression: membership)
    }
    return next
}

/// Factory for `@HasMany(through:from:to:)`'s generated registry entry.
///
/// Two batched queries, never a SQL join — the same shape as every other
/// preload: join-table rows filtered by `throughFrom = ANY(parentKeys)`,
/// then related rows filtered by `childKey = ANY(collected to-keys)`, then
/// in-memory reassembly. Per-parent ordering honors the tuned child query's
/// own order. Duplicate join rows yield duplicate children — the honest
/// reflection of the data — and a join row referencing a vanished child is
/// skipped, matching the direct has-many's inner-join semantics.
public func _hasManyThrough<
    Parent: Table, Through: Table, Child: Table,
    ParentKey: PreloadKey, ChildKey: PreloadKey
>(
    name: String,
    parentKey: KeyPath<Parent, ParentKey> & Sendable,
    throughFrom: KeyPath<Through, ParentKey> & Sendable,
    throughTo: KeyPath<Through, ChildKey> & Sendable,
    childKey: KeyPath<Child, ChildKey> & Sendable,
    target: WritableKeyPath<Parent, Loadable<[Child]>> & Sendable
) -> _HasManyThroughLoader<Parent, Child> {
    _HasManyThroughLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let parentKeys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let throughRows = try await repo.all(
            filtered(Through.all, by: throughFrom, in: parentKeys, association: name))

        let childKeys = Array(Set(throughRows.map { $0[keyPath: throughTo] }))
        let children: [Child] =
            childKeys.isEmpty
            ? []
            : try await repo.all(
                filtered(tune(Child.all), by: childKey, in: childKeys, association: name))

        let childByKey = Dictionary(
            children.map { ($0[keyPath: childKey], $0) },
            uniquingKeysWith: { first, _ in first })
        // The tuned child query's own order, applied per parent.
        let orderIndex = Dictionary(
            children.enumerated().map { ($1[keyPath: childKey], $0) },
            uniquingKeysWith: { first, _ in first })
        var keysByParent: [ParentKey: [ChildKey]] = [:]
        for row in throughRows {
            keysByParent[row[keyPath: throughFrom], default: []]
                .append(row[keyPath: throughTo])
        }

        for index in parents.indices {
            let key = parents[index][keyPath: parentKey]
            let related = (keysByParent[key] ?? [])
                .compactMap { childByKey[$0] }
                .sorted {
                    (orderIndex[$0[keyPath: childKey]] ?? .max)
                        < (orderIndex[$1[keyPath: childKey]] ?? .max)
                }
            parents[index][keyPath: target] = .loaded(related)
        }
    }
}

// MARK: - Query surface

/// One pending preload on a query — everything about the association is
/// captured typed at the `.preload` call site; execution happens in
/// `Repo.all` after the parent rows decode.
struct PreloadStep<Model: Table>: Sendable {
    let run: @Sendable (inout [Model], Repo) async throws -> Void
}

// The two step builders below exist so the association-registry dispatch
// lives in exactly one place: `Query.preload` and `QueryBuilder.preload`
// (the composed-join builder) both need it, and a second copy is how the
// two spellings would drift into answering differently.
extension PreloadStep {
    /// A has-many step — direct or through; the call site never needs to
    /// know which, so the discrimination happens here.
    static func hasMany<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<[Child]>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
    ) -> PreloadStep<Model> {
        PreloadStep { parents, repo in
            let erased = Model._association(for: association)
            if let loader = erased as? _HasManyLoader<Model, Child> {
                try await loader.run(&parents, repo, nested)
            } else if let loader = erased as? _HasManyThroughLoader<Model, Child> {
                try await loader.run(&parents, repo, nested)
            } else {
                throw HangarError.unknownAssociation(
                    table: Model.schema.name, association: "\(association)")
            }
        }
    }

    /// A to-one step, for whichever loader type the call site expects.
    static func toOne<Loader>(
        _ association: AnyKeyPath & Sendable,
        _ execute: @escaping @Sendable (Loader, inout [Model], Repo) async throws -> Void
    ) -> PreloadStep<Model> {
        PreloadStep { parents, repo in
            guard let loader = Model._association(for: association) as? Loader else {
                throw HangarError.unknownAssociation(
                    table: Model.schema.name, association: "\(association)")
            }
            try await execute(loader, &parents, repo)
        }
    }
}

extension Query {
    /// Preloads a `@HasMany` association, optionally tuning the child query
    /// (ordering, filtering, its own nested `.preload`s):
    ///
    /// ```swift
    /// Post.where { $0.published }
    ///.preload(\.comments) { $0.order { $0.createdAt.asc }.preload(\.author) }
    /// ```
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<[Child]>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        var next = self
        next.preloads.append(.hasMany(association, nested))
        return next
    }

    /// Preloads a `@BelongsTo` association with a non-optional foreign key.
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<Child>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        appendingPreload(association) { (loader: _ToOneLoader<Model, Child>, parents, repo) in
            try await loader.run(&parents, repo, nested)
        }
    }

    /// Preloads a `@HasOne`, or a `@BelongsTo` over a nullable foreign key.
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<Child?>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        appendingPreload(association) {
            (loader: _OptionalToOneLoader<Model, Child>, parents, repo) in
            try await loader.run(&parents, repo, nested)
        }
    }

    private func appendingPreload<Loader>(
        _ association: AnyKeyPath & Sendable,
        _ execute: @escaping @Sendable (Loader, inout [Model], Repo) async throws -> Void
    ) -> Query<Model, Result> {
        var next = self
        next.preloads.append(.toOne(association, execute))
        return next
    }
}
