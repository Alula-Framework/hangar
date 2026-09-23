// Design  — the macro expansion fixtures, written first, implemented
// against. These expected-output strings ARE the specification of @Entity's
// expansion; the original prose examples are illustrative, these are
// normative.
//
// Cases follow the list, restricted to Phase 1–2 scope: plain table,
// custom column names, optionals, enum column, JSONB, composite PK,
// database-generated key, access-level matching, and the diagnostics.
// Since Phase 2 (changeset integration, the design) every entity also
// gets a `Changesets.TableModel` conformance: `tableName`, the `columns`
// keypath catalog, and the `_changesetBind` erased-value switch. Hangar's
// own column DSL sits under `queryColumns` — renamed from Phase 1's
// `columns` to leave that name to TableModel (see README).
// Association fixtures (has-many, belongs-to) arrive with Phase 3.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import HangarMacrosImpl

// MacroSpec so the harness knows the conformances @attached(extension)
// declares — without it the extension macro receives an empty `protocols`
// list and emits nothing (same first-run finding as Alula Core).
private let testMacros: [String: MacroSpec] = [
    "Entity": MacroSpec(
        type: EntityMacro.self, conformances: ["Hangar.Table", "Changesets.TableModel"]),
    "ID": MacroSpec(type: IDMacro.self),
    "Column": MacroSpec(type: ColumnNameMacro.self),
    "JSONB": MacroSpec(type: JSONBMacro.self),
]

final class EntityMacroFixtureTests: XCTestCase {

    // MARK: Fixture 1 — plain table (snake_case naming, incl. acronym run)

    func testPlainTable() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var title: String
                var viewCount: Int
                let authorID: UUID
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var title: String
                var viewCount: Int
                let authorID: UUID

                struct Columns: Hangar.AliasableColumns {
                    let id: Hangar.Column<UUID>
                    let title: Hangar.Column<String>
                    let viewCount: Hangar.Column<Int>
                    let authorID: Hangar.Column<UUID>
                    init() {
                        self.init(table: "posts")
                    }
                    init(table: String) {
                        self.id = Hangar.Column<UUID>("id", table: table)
                        self.title = Hangar.Column<String>("title", table: table)
                        self.viewCount = Hangar.Column<Int>("view_count", table: table)
                        self.authorID = Hangar.Column<UUID>("author_id", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "posts",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "title", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "view_count", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "author_id", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "posts"

                static let columns: [Changesets.TableColumn<Post>] = [
                    Changesets.TableColumn("id", \\Post.id, primaryKey: true),
                    Changesets.TableColumn("title", \\Post.title),
                    Changesets.TableColumn("view_count", \\Post.viewCount),
                    Changesets.TableColumn("author_id", \\Post.authorID),
                ]

                init(id: UUID, title: String, viewCount: Int, authorID: UUID) {
                    self.id = id
                    self.title = title
                    self.viewCount = viewCount
                    self.authorID = authorID
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 4, table: "posts")
                    self.id = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "posts", column: "id")
                    self.title = try Hangar._decodeColumn(String.self, from: cells[1], table: "posts", column: "title")
                    self.viewCount = try Hangar._decodeColumn(Int.self, from: cells[2], table: "posts", column: "view_count")
                    self.authorID = try Hangar._decodeColumn(UUID.self, from: cells[3], table: "posts", column: "author_id")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    case "title":
                        return Hangar.SQLBind(self.title)
                    case "view_count":
                        return Hangar.SQLBind(self.viewCount)
                    case "author_id":
                        return Hangar.SQLBind(self.authorID)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "title":
                        return (value as? String).map {
                            Hangar.SQLBind($0)
                        }
                    case "view_count":
                        return (value as? Int).map {
                            Hangar.SQLBind($0)
                        }
                    case "author_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 2 — custom column name, optionals, and a var default
    // (public type, so the generated surface is access-matched)

    func testCustomNamesOptionalsAndDefaults() {
        assertMacroExpansion(
            """
            @Entity("users")
            public struct User: Sendable {
                @ID let id: UUID
                @Column("email_address") var email: String
                var nickname: String?
                var loginCount: Int = 0
            }
            """,
            expandedSource: """
            public struct User: Sendable {
                let id: UUID
                var email: String
                var nickname: String?
                var loginCount: Int = 0

                public struct Columns: Hangar.AliasableColumns {
                    public let id: Hangar.Column<UUID>
                    public let email: Hangar.Column<String>
                    public let nickname: Hangar.Column<String?>
                    public let loginCount: Hangar.Column<Int>
                    public init() {
                        self.init(table: "users")
                    }
                    public init(table: String) {
                        self.id = Hangar.Column<UUID>("id", table: table)
                        self.email = Hangar.Column<String>("email_address", table: table)
                        self.nickname = Hangar.Column<String?>("nickname", table: table)
                        self.loginCount = Hangar.Column<Int>("login_count", table: table)
                    }
                }

                public static let queryColumns = Columns()

                public static let schema = Hangar.TableSchema(
                    name: "users",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "email_address", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "nickname", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "login_count", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                public static let tableName = "users"

                public static let columns: [Changesets.TableColumn<User>] = [
                    Changesets.TableColumn("id", \\User.id, primaryKey: true),
                    Changesets.TableColumn("email_address", \\User.email),
                    Changesets.TableColumn("nickname", \\User.nickname),
                    Changesets.TableColumn("login_count", \\User.loginCount),
                ]

                public init(id: UUID, email: String, nickname: String? = nil, loginCount: Int = 0) {
                    self.id = id
                    self.email = email
                    self.nickname = nickname
                    self.loginCount = loginCount
                }

                public init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 4, table: "users")
                    self.id = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "users", column: "id")
                    self.email = try Hangar._decodeColumn(String.self, from: cells[1], table: "users", column: "email_address")
                    self.nickname = try Hangar._decodeColumn(String?.self, from: cells[2], table: "users", column: "nickname")
                    self.loginCount = try Hangar._decodeColumn(Int.self, from: cells[3], table: "users", column: "login_count")
                }

                public func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    case "email_address":
                        return Hangar.SQLBind(self.email)
                    case "nickname":
                        return Hangar.SQLBind(self.nickname)
                    case "login_count":
                        return Hangar.SQLBind(self.loginCount)
                    default:
                        return nil
                    }
                }

                public static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "email_address":
                        return (value as? String).map {
                            Hangar.SQLBind($0)
                        }
                    case "nickname":
                        return (value as? String?).map {
                            Hangar.SQLBind($0)
                        }
                    case "login_count":
                        return (value as? Int).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }
            }

            extension User: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 3 — enum column and JSONB (required + optional)
    // Pins that a PostgresEnum column needs no special casing in the macro:
    // the expansion is identical to a plain column's; the enum's encoding
    // lives entirely in the PostgresEnum conformance.

    func testEnumAndJSONBColumns() {
        assertMacroExpansion(
            """
            @Entity("articles")
            struct Article: Sendable {
                @ID let id: UUID
                var status: Status
                @JSONB var metadata: ArticleMetadata
                @JSONB var draft: DraftState?
            }
            """,
            expandedSource: """
            struct Article: Sendable {
                let id: UUID
                var status: Status
                var metadata: ArticleMetadata
                var draft: DraftState?

                struct Columns: Hangar.AliasableColumns {
                    let id: Hangar.Column<UUID>
                    let status: Hangar.Column<Status>
                    let metadata: Hangar.Column<ArticleMetadata>
                    let draft: Hangar.Column<DraftState?>
                    init() {
                        self.init(table: "articles")
                    }
                    init(table: String) {
                        self.id = Hangar.Column<UUID>("id", table: table)
                        self.status = Hangar.Column<Status>("status", table: table)
                        self.metadata = Hangar.Column<ArticleMetadata>("metadata", table: table)
                        self.draft = Hangar.Column<DraftState?>("draft", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "articles",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "status", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "metadata", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "draft", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "articles"

                static let columns: [Changesets.TableColumn<Article>] = [
                    Changesets.TableColumn("id", \\Article.id, primaryKey: true),
                    Changesets.TableColumn("status", \\Article.status),
                    Changesets.TableColumn("metadata", \\Article.metadata),
                    Changesets.TableColumn("draft", \\Article.draft),
                ]

                init(id: UUID, status: Status, metadata: ArticleMetadata, draft: DraftState? = nil) {
                    self.id = id
                    self.status = status
                    self.metadata = metadata
                    self.draft = draft
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 4, table: "articles")
                    self.id = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "articles", column: "id")
                    self.status = try Hangar._decodeColumn(Status.self, from: cells[1], table: "articles", column: "status")
                    self.metadata = try Hangar._decodeJSONB(ArticleMetadata.self, from: cells[2], table: "articles", column: "metadata")
                    self.draft = try Hangar._decodeOptionalJSONB(DraftState.self, from: cells[3], table: "articles", column: "draft")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    case "status":
                        return Hangar.SQLBind(self.status)
                    case "metadata":
                        return Hangar.SQLBind(jsonb: self.metadata)
                    case "draft":
                        return Hangar.SQLBind(jsonb: self.draft)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "status":
                        return (value as? Status).map {
                            Hangar.SQLBind($0)
                        }
                    case "metadata":
                        return (value as? ArticleMetadata).map {
                            Hangar.SQLBind(jsonb: $0)
                        }
                    case "draft":
                        return (value as? DraftState?).map {
                            Hangar.SQLBind(jsonb: $0)
                        }
                    default:
                        return nil
                    }
                }
            }

            extension Article: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 4 — composite primary key

    func testCompositePrimaryKey() {
        assertMacroExpansion(
            """
            @Entity("post_tags")
            struct PostTag: Sendable {
                @ID let postID: UUID
                @ID let tagID: UUID
                var position: Int
            }
            """,
                        expandedSource: """
            struct PostTag: Sendable {
                let postID: UUID
                let tagID: UUID
                var position: Int

                struct Columns: Hangar.AliasableColumns {
                    let postID: Hangar.Column<UUID>
                    let tagID: Hangar.Column<UUID>
                    let position: Hangar.Column<Int>
                    init() {
                        self.init(table: "post_tags")
                    }
                    init(table: String) {
                        self.postID = Hangar.Column<UUID>("post_id", table: table)
                        self.tagID = Hangar.Column<UUID>("tag_id", table: table)
                        self.position = Hangar.Column<Int>("position", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "post_tags",
                    columns: [
                        Hangar.ColumnDefinition(name: "post_id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "tag_id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "position", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "post_tags"

                static let columns: [Changesets.TableColumn<PostTag>] = [
                    Changesets.TableColumn("post_id", \\PostTag.postID, primaryKey: true),
                    Changesets.TableColumn("tag_id", \\PostTag.tagID, primaryKey: true),
                    Changesets.TableColumn("position", \\PostTag.position),
                ]

                init(postID: UUID, tagID: UUID, position: Int) {
                    self.postID = postID
                    self.tagID = tagID
                    self.position = position
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 3, table: "post_tags")
                    self.postID = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "post_tags", column: "post_id")
                    self.tagID = try Hangar._decodeColumn(UUID.self, from: cells[1], table: "post_tags", column: "tag_id")
                    self.position = try Hangar._decodeColumn(Int.self, from: cells[2], table: "post_tags", column: "position")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "post_id":
                        return Hangar.SQLBind(self.postID)
                    case "tag_id":
                        return Hangar.SQLBind(self.tagID)
                    case "position":
                        return Hangar.SQLBind(self.position)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "post_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "tag_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "position":
                        return (value as? Int).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }
            }

            extension PostTag: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 5 — database-generated key (bigserial / identity)

    func testGeneratedKey() {
        assertMacroExpansion(
            """
            @Entity("events")
            struct Event: Sendable {
                @ID(generated: true) var id: Int = 0
                var name: String
            }
            """,
            expandedSource: """
            struct Event: Sendable {
                var id: Int = 0
                var name: String

                struct Columns: Hangar.AliasableColumns {
                    let id: Hangar.Column<Int>
                    let name: Hangar.Column<String>
                    init() {
                        self.init(table: "events")
                    }
                    init(table: String) {
                        self.id = Hangar.Column<Int>("id", table: table)
                        self.name = Hangar.Column<String>("name", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "events",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: true, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "name", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "events"

                static let columns: [Changesets.TableColumn<Event>] = [
                    Changesets.TableColumn("id", \\Event.id, primaryKey: true),
                    Changesets.TableColumn("name", \\Event.name),
                ]

                init(id: Int = 0, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 2, table: "events")
                    self.id = try Hangar._decodeColumn(Int.self, from: cells[0], table: "events", column: "id")
                    self.name = try Hangar._decodeColumn(String.self, from: cells[1], table: "events", column: "name")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    case "name":
                        return Hangar.SQLBind(self.name)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? Int).map {
                            Hangar.SQLBind($0)
                        }
                    case "name":
                        return (value as? String).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }
            }

            extension Event: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Diagnostics

    func testRejectsClass() {
        assertMacroExpansion(
            """
            @Entity("posts")
            class Post {
                @ID let id: UUID = UUID()
            }
            """,
            expandedSource: """
            class Post {
                let id: UUID = UUID()
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity can only be attached to a struct — models are values.",
                    line: 1, column: 1)
            ],
            macroSpecs: testMacros
        )
    }

    func testRequiresPrimaryKey() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                var title: String
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                var title: String
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity needs a primary key — mark one or more properties with @ID.",
                    line: 1, column: 1)
            ],
            macroSpecs: testMacros
        )
    }

    func testRequiresTypeAnnotation() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var title = "untitled"
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var title = "untitled"
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity properties need an explicit type annotation — the column's Swift type is read from it.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    func testRejectsInitializedLet() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                let kind: String = "post"
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                let kind: String = "post"
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "A 'let' with an initializer can't be decoded from a row (the value is already fixed). Make it 'var' or drop the initializer.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: snake_case unit coverage

    func testSnakeCase() {
        XCTAssertEqual(snakeCase("title"), "title")
        XCTAssertEqual(snakeCase("viewCount"), "view_count")
        XCTAssertEqual(snakeCase("authorID"), "author_id")
        XCTAssertEqual(snakeCase("createdAt"), "created_at")
        XCTAssertEqual(snakeCase("url"), "url")
        XCTAssertEqual(snakeCase("URLString"), "url_string")
        XCTAssertEqual(snakeCase("id"), "id")
        XCTAssertEqual(snakeCase("userV2Flag"), "user_v2_flag")
    }
}

// MARK: - Phase 3: associations

final class EntityAssociationFixtureTests: XCTestCase {

    // MARK: Fixture 6 — all three association kinds

    func testAssociations() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var title: String
                let authorID: UUID

                @HasMany(foreignKey: \\Comment.postID)
                var comments: Loadable<[Comment]>

                @BelongsTo(foreignKey: \\Post.authorID)
                var author: Loadable<Author>

                @HasOne(foreignKey: \\Extra.postID)
                var extra: Loadable<Extra?>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var title: String
                let authorID: UUID
                var comments: Loadable<[Comment]>
                var author: Loadable<Author>
                var extra: Loadable<Extra?>

                struct Columns: Hangar.AliasableColumns {
                    let id: Hangar.Column<UUID>
                    let title: Hangar.Column<String>
                    let authorID: Hangar.Column<UUID>
                    init() {
                        self.init(table: "posts")
                    }
                    init(table: String) {
                        self.id = Hangar.Column<UUID>("id", table: table)
                        self.title = Hangar.Column<String>("title", table: table)
                        self.authorID = Hangar.Column<UUID>("author_id", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "posts",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "title", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "author_id", isPrimaryKey: false, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "posts"

                static let columns: [Changesets.TableColumn<Post>] = [
                    Changesets.TableColumn("id", \\Post.id, primaryKey: true),
                    Changesets.TableColumn("title", \\Post.title),
                    Changesets.TableColumn("author_id", \\Post.authorID),
                ]

                init(id: UUID, title: String, authorID: UUID, comments: Loadable<[Comment]> = .notLoaded(association: "comments"), author: Loadable<Author> = .notLoaded(association: "author"), extra: Loadable<Extra?> = .notLoaded(association: "extra")) {
                    self.id = id
                    self.title = title
                    self.authorID = authorID
                    self.comments = comments
                    self.author = author
                    self.extra = extra
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 3, table: "posts")
                    self.id = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "posts", column: "id")
                    self.title = try Hangar._decodeColumn(String.self, from: cells[1], table: "posts", column: "title")
                    self.authorID = try Hangar._decodeColumn(UUID.self, from: cells[2], table: "posts", column: "author_id")
                    self.comments = .notLoaded(association: "comments")
                    self.author = .notLoaded(association: "author")
                    self.extra = .notLoaded(association: "extra")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    case "title":
                        return Hangar.SQLBind(self.title)
                    case "author_id":
                        return Hangar.SQLBind(self.authorID)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "title":
                        return (value as? String).map {
                            Hangar.SQLBind($0)
                        }
                    case "author_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }

                static func _association(for keyPath: AnyKeyPath) -> (any Sendable)? {
                    if keyPath == \\Post.comments {
                        return Hangar._hasMany(name: "comments", parentKey: \\Post.id, foreignKey: \\Comment.postID, target: \\Post.comments)
                    }
                    if keyPath == \\Post.author {
                        return Hangar._belongsTo(name: "author", foreignKey: \\Post.authorID, references: \\Author.id, target: \\Post.author)
                    }
                    if keyPath == \\Post.extra {
                        return Hangar._hasOne(name: "extra", parentKey: \\Post.id, foreignKey: \\Extra.postID, target: \\Post.extra)
                    }
                    return nil
                }
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: associationTestMacros
        )
    }

    // MARK: Diagnostics

    func testLoadableRequiresAssociationAttribute() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var comments: Loadable<[Comment]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var comments: Loadable<[Comment]>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "A Loadable property needs an association attribute — mark it @HasMany, @BelongsTo, or @HasOne.",
                    line: 4, column: 5)
            ],
            macroSpecs: associationTestMacros
        )
    }

    func testHasOneRequiresOptionalTarget() {
        assertMacroExpansion(
            """
            @Entity("authors")
            struct Author: Sendable {
                @ID let id: UUID
                @HasOne(foreignKey: \\Profile.authorID)
                var profile: Loadable<Profile>
            }
            """,
            expandedSource: """
            struct Author: Sendable {
                let id: UUID
                var profile: Loadable<Profile>
            }

            extension Author: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasOne properties must be Loadable<Related?> — \"no related row\" is data, expressed as .loaded(nil).",
                    line: 4, column: 5)
            ],
            macroSpecs: associationTestMacros
        )
    }

    func testAssociationMustBeVar() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany(foreignKey: \\Comment.postID)
                let comments: Loadable<[Comment]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                let comments: Loadable<[Comment]>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany properties must be 'var' — preload assigns into them.",
                    line: 4, column: 5)
            ],
            macroSpecs: associationTestMacros
        )
    }
}

private let associationTestMacros: [String: MacroSpec] = [
    "Entity": MacroSpec(
        type: EntityMacro.self, conformances: ["Hangar.Table", "Changesets.TableModel"]),
    "ID": MacroSpec(type: IDMacro.self),
    "HasMany": MacroSpec(type: HasManyMacro.self),
    "BelongsTo": MacroSpec(type: BelongsToMacro.self),
    "HasOne": MacroSpec(type: HasOneMacro.self),
]

final class ThroughAssociationFixtureTests: XCTestCase {
    func testThroughExpansion() {
        // The registry branch for @HasMany(through:) — childKey follows the
        // related type's `id` by convention, exactly as @BelongsTo's
        // `references` default does.
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany(through: PostTag.self, from: \\PostTag.postID, to: \\PostTag.tagID)
                var tags: Loadable<[Tag]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany(through: PostTag.self, from: \\PostTag.postID, to: \\PostTag.tagID)
                var tags: Loadable<[Tag]>

                struct Columns: Hangar.AliasableColumns {
                    let id: Hangar.Column<UUID>
                    init() {
                        self.init(table: "posts")
                    }
                    init(table: String) {
                        self.id = Hangar.Column<UUID>("id", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "posts",
                    columns: [
                        Hangar.ColumnDefinition(name: "id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "posts"

                static let columns: [Changesets.TableColumn<Post>] = [
                    Changesets.TableColumn("id", \\Post.id, primaryKey: true),
                ]

                init(id: UUID, tags: Loadable<[Tag]> = .notLoaded(association: "tags")) {
                    self.id = id
                    self.tags = tags
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 1, table: "posts")
                    self.id = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "posts", column: "id")
                    self.tags = .notLoaded(association: "tags")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return Hangar.SQLBind(self.id)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }

                static func _association(for keyPath: AnyKeyPath) -> (any Sendable)? {
                    if keyPath == \\Post.tags {
                        return Hangar._hasManyThrough(name: "tags", parentKey: \\Post.id, throughFrom: \\PostTag.postID, throughTo: \\PostTag.tagID, childKey: \\Tag.id, target: \\Post.tags)
                    }
                    return nil
                }
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            macroSpecs: testMacros)
    }
}

/// The diagnostics that had no fixture: every message a misuse produces is
/// pinned here, so a rewording or a silently-vanished diagnostic fails a
/// test rather than shipping.
final class EntityDiagnosticFixtureTests: XCTestCase {

    func testTableNameMustBeStringLiteral() {
        assertMacroExpansion(
            """
            @Entity(someVariable)
            struct Post: Sendable {
                @ID let id: UUID
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity needs a static string literal table name: @Entity(\"posts\").",
                    line: 1, column: 1)
            ],
            macroSpecs: testMacros)
    }

    func testEmptyEntityIsRejected() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
            }
            """,
            expandedSource: """
            struct Post: Sendable {
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity struct has no stored properties — a table needs at least one column.",
                    line: 1, column: 1)
            ],
            macroSpecs: testMacros)
    }

    func testMultiBindingIsRejected() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var width, height: Int
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var width, height: Int
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity properties must be declared one per line — split 'let a, b: T' into separate declarations.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testTuplePatternIsRejected() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                var (x, y): (Int, Int)
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var (x, y): (Int, Int)
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Entity properties must be simple identifiers — tuple patterns can't map to columns.",
                    line: 4, column: 9)
            ],
            macroSpecs: testMacros)
    }

    func testColumnNameMustBeStringLiteral() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @Column(someVariable) var title: String
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                var title: String
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Column needs a static string literal column name.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testAssociationCannotBeAColumn() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @Column("tags") @HasMany(foreignKey: \\Tag.postID)
                var tags: Loadable<[Tag]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany(foreignKey: \\Tag.postID)
                var tags: Loadable<[Tag]>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany can't combine with @ID/@Column/@JSONB — an association is not a column.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testAssociationMustBeLoadable() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany(foreignKey: \\Tag.postID)
                var tags: [Tag]
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany(foreignKey: \\Tag.postID)
                var tags: [Tag]
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany properties must be Loadable — the runtime marker for \"populated only by preload\".",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testHasManyNeedsArrayShape() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany(foreignKey: \\Tag.postID)
                var tag: Loadable<Tag>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany(foreignKey: \\Tag.postID)
                var tag: Loadable<Tag>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany properties must be Loadable<[Related]>.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testAssociationNeedsForeignKey() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany
                var tags: Loadable<[Tag]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany
                var tags: Loadable<[Tag]>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany needs a foreignKey: keypath argument.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testBelongsToRejectsArrayShape() {
        assertMacroExpansion(
            """
            @Entity("comments")
            struct Comment: Sendable {
                @ID let id: UUID
                @BelongsTo(foreignKey: \\Comment.authorID)
                var authors: Loadable<[Author]>
            }
            """,
            expandedSource: """
            struct Comment: Sendable {
                let id: UUID
                @BelongsTo(foreignKey: \\Comment.authorID)
                var authors: Loadable<[Author]>
            }

            extension Comment: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@BelongsTo properties must be Loadable<Related> (non-null foreign key) or Loadable<Related?> (nullable) — for a collection, use @HasMany.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testThroughIsHasManyOnly() {
        assertMacroExpansion(
            """
            @Entity("comments")
            struct Comment: Sendable {
                @ID let id: UUID
                @BelongsTo(through: PostTag.self, from: \\PostTag.postID, to: \\PostTag.tagID)
                var author: Loadable<Author>
            }
            """,
            expandedSource: """
            struct Comment: Sendable {
                let id: UUID
                @BelongsTo(through: PostTag.self, from: \\PostTag.postID, to: \\PostTag.tagID)
                var author: Loadable<Author>
            }

            extension Comment: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "through: is @HasMany-only — @BelongsTo is a single-hop association.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testThroughNeedsFromAndTo() {
        assertMacroExpansion(
            """
            @Entity("posts")
            struct Post: Sendable {
                @ID let id: UUID
                @HasMany(through: PostTag.self)
                var tags: Loadable<[Tag]>
            }
            """,
            expandedSource: """
            struct Post: Sendable {
                let id: UUID
                @HasMany(through: PostTag.self)
                var tags: Loadable<[Tag]>
            }

            extension Post: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@HasMany(through:) needs from: and to: keypaths on the join table — from: references this entity's key, to: the related entity's.",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testMarkerOnNonProperty() {
        assertMacroExpansion(
            """
            struct Post {
                @ID func compute() -> Int { 1 }
            }
            """,
            expandedSource: """
            struct Post {
                func compute() -> Int { 1 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ID can only be attached to a stored property of an @Entity struct.",
                    line: 2, column: 5)
            ],
            macroSpecs: testMacros)
    }

    func testMarkerNeedsTypeAnnotation() {
        assertMacroExpansion(
            """
            struct Post {
                @Column("n") var n = 3
            }
            """,
            expandedSource: """
            struct Post {
                var n = 3
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Column properties need an explicit type annotation — the column's Swift type is read from it.",
                    line: 2, column: 5)
            ],
            macroSpecs: testMacros)
    }
}

final class CompositeKeyAssociationFixtureTests: XCTestCase {
    /// A composite-key entity's has-many batches on the first `@ID`. That
    /// is a convention, not a deduction, so the macro says so at build
    /// time rather than letting it be discovered as wrong rows.
    func testCompositeKeyHasManyWarns() {
        assertMacroExpansion(
            """
            @Entity("post_tags")
            struct PostTag: Sendable {
                @ID let postID: UUID
                @ID let tagID: UUID
                @HasMany(foreignKey: \\Note.postID)
                var notes: Loadable<[Note]>
            }
            """,
            expandedSource: """
            struct PostTag: Sendable {
                let postID: UUID
                let tagID: UUID
                var notes: Loadable<[Note]>

                struct Columns: Hangar.AliasableColumns {
                    let postID: Hangar.Column<UUID>
                    let tagID: Hangar.Column<UUID>
                    init() {
                        self.init(table: "post_tags")
                    }
                    init(table: String) {
                        self.postID = Hangar.Column<UUID>("post_id", table: table)
                        self.tagID = Hangar.Column<UUID>("tag_id", table: table)
                    }
                }

                static let queryColumns = Columns()

                static let schema = Hangar.TableSchema(
                    name: "post_tags",
                    columns: [
                        Hangar.ColumnDefinition(name: "post_id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                        Hangar.ColumnDefinition(name: "tag_id", isPrimaryKey: true, isGenerated: false, isDeletedAt: false),
                    ]
                )

                static let tableName = "post_tags"

                static let columns: [Changesets.TableColumn<PostTag>] = [
                    Changesets.TableColumn("post_id", \\PostTag.postID, primaryKey: true),
                    Changesets.TableColumn("tag_id", \\PostTag.tagID, primaryKey: true),
                ]

                init(postID: UUID, tagID: UUID, notes: Loadable<[Note]> = .notLoaded(association: "notes")) {
                    self.postID = postID
                    self.tagID = tagID
                    self.notes = notes
                }

                init(from row: PostgresRow) throws {
                    let cells = row.makeRandomAccess()
                    try Hangar._checkColumnCount(cells.count, expected: 2, table: "post_tags")
                    self.postID = try Hangar._decodeColumn(UUID.self, from: cells[0], table: "post_tags", column: "post_id")
                    self.tagID = try Hangar._decodeColumn(UUID.self, from: cells[1], table: "post_tags", column: "tag_id")
                    self.notes = .notLoaded(association: "notes")
                }

                func _bind(for column: String) -> Hangar.SQLBind? {
                    switch column {
                    case "post_id":
                        return Hangar.SQLBind(self.postID)
                    case "tag_id":
                        return Hangar.SQLBind(self.tagID)
                    default:
                        return nil
                    }
                }

                static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                    switch column {
                    case "post_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    case "tag_id":
                        return (value as? UUID).map {
                            Hangar.SQLBind($0)
                        }
                    default:
                        return nil
                    }
                }

                static func _association(for keyPath: AnyKeyPath) -> (any Sendable)? {
                    if keyPath == \\PostTag.notes {
                        return Hangar._hasMany(name: "notes", parentKey: \\PostTag.postID, foreignKey: \\Note.postID, target: \\PostTag.notes)
                    }
                    return nil
                }
            }

            extension PostTag: Hangar.Table, Changesets.TableModel {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "this entity has a composite key (postID, tagID), so notes will batch on 'postID' alone. If the child references the other key column, preload it through an explicit query instead.",
                    line: 1, column: 1, severity: .warning)
            ],
            macroSpecs: associationTestMacros)
    }
}
