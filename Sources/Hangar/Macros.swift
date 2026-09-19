/// `@Entity("posts")` — the macro that makes a struct a Hangar table
///. Generates:
///
/// 1. `Columns` — one typed `Column<T>` per stored property, for the
///    closure-based operators.
/// 2. A positional row decoder, `init(from: PostgresRow)` — compile-time
///    generated, no reflection, no string-keyed lookup per field.
/// 3. Table metadata (`schema`) — name, columns, primary key, insertable
///    vs. generated.
/// 4. A memberwise initializer (macro-generated because the compiler stops
///    synthesizing one once the macro adds `init(from:)`).
///
/// Association metadata (`@HasMany` et al.) arrives in Phase 3.
///
/// Table name is explicit — no pluralization inference, because inference
/// is wrong often enough that guessing costs more than typing.
///
/// Also generates the `Changesets.TableModel` conformance:
/// `tableName`, the `columns` keypath catalog, and the erased-value bind
/// switch — so `Changeset(Post.self)` and `repo.insert(changeset)` work
/// with no extra declarations.
@attached(
    member,
    names: named(Columns), named(queryColumns), named(schema), named(tableName),
    named(columns), named(init), named(_bind(for:)),
    named(_changesetBind(column:value:)), named(_association(for:)))
@attached(extension, conformances: Table, TableModel)
/// Declares a struct as a table-backed entity: generates the typed
/// column set, schema metadata, row decoder, changeset metadata, and
/// association registry — the whole `Table` conformance.
public macro Entity(_ tableName: String) =
    #externalMacro(module: "HangarMacrosImpl", type: "EntityMacro")

/// Marks the primary key (composite keys: multiple `@ID` properties).
/// `generated: true` means the database produces the value (identity /
/// serial / default) — the column is excluded from INSERT lists and read
/// back via RETURNING.
@attached(peer)
public macro ID(generated: Bool = false) =
    #externalMacro(module: "HangarMacrosImpl", type: "IDMacro")

/// Overrides the default camelCase → snake_case column naming:
/// `@Column("created_at") var createdAt: Date`.
@attached(peer)
public macro Column(_ name: String) =
    #externalMacro(module: "HangarMacrosImpl", type: "ColumnNameMacro")

/// Stores any `Codable` property as a `jsonb` column.
@attached(peer)
public macro JSONB() =
    #externalMacro(module: "HangarMacrosImpl", type: "JSONBMacro")

/// Marks the column that records when a row was soft-deleted, making the
/// entity soft-deletable: `@Deleted var deletedAt: Date?`.
///
/// Once a model has one, reads exclude deleted rows by default and
/// `repo.delete` stamps the column instead of issuing a `DELETE`. Both are
/// opt-out — see ``Query/withDeleted()`` and ``Repo/forceDelete(_:)``.
///
/// The property must be an optional date: `nil` is what "not deleted" means,
/// and a non-optional column could not express it.
@attached(peer)
public macro Deleted() =
    #externalMacro(module: "HangarMacrosImpl", type: "DeletedMacro")

/// A one-to-many association: `foreignKey` is the child
/// column that references this table (the parent's primary key by
/// default). The property must be `var name: Loadable<[Child]>` — not a
/// column; populated only by `.preload`.
///
/// ```swift
/// @HasMany(foreignKey: \Comment.postID) var comments: Loadable<[Comment]>
/// ```
@attached(peer)
public macro HasMany(foreignKey: AnyKeyPath) =
    #externalMacro(module: "HangarMacrosImpl", type: "HasManyMacro")

/// A many-to-many association loaded through a join table:
///
/// ```swift
/// @HasMany(through: PostTag.self, from: \PostTag.postID, to: \PostTag.tagID)
/// var tags: Loadable<[Tag]> = .notLoaded(association: "tags")
/// ```
///
/// `through` is the join table's entity; `from` is its column referencing
/// *this* entity's primary key; `to` is its column referencing the related
/// entity's primary key. Preloading issues two batched queries — one
/// against the join table, one against the related table — never a SQL
/// join, exactly like every other preload.
@attached(peer)
public macro HasMany(through: Any.Type, from: AnyKeyPath, to: AnyKeyPath) =
    #externalMacro(module: "HangarMacrosImpl", type: "HasManyMacro")

/// A child-side association: `foreignKey` is *this* table's column
/// referencing the related row; `references` is the related column it
/// points at (the related type's `id` by default, Ecto's convention). A
/// non-optional foreign key pairs with `Loadable<Related>`; a nullable one
/// with `Loadable<Related?>` (`.loaded(nil)` = no reference).
@attached(peer)
public macro BelongsTo(foreignKey: AnyKeyPath, references: AnyKeyPath? = nil) =
    #externalMacro(module: "HangarMacrosImpl", type: "BelongsToMacro")

/// A one-to-zero-or-one association: like `@HasMany` but the
/// property is `Loadable<Related?>` — absence is data (`.loaded(nil)`),
/// distinct from not-preloaded.
@attached(peer)
public macro HasOne(foreignKey: AnyKeyPath) =
    #externalMacro(module: "HangarMacrosImpl", type: "HasOneMacro")
