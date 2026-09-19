import Foundation
import Testing

@testable import Hangar

@Suite("SQL renderer — AST → SQL + ordered binds")
struct RendererTests {

    private let allColumns =
        #""id", "title", "published", "view_count", "created_at", "nickname", "status", "metadata", "author_id""#

    @Test("select with no conditions lists every column explicitly, never *")
    func selectAll() {
        let statement = SQLRenderer.select(Post.all)
        #expect(statement.sql == #"SELECT \#(allColumns) FROM "hangar_posts""#)
        #expect(statement.binds.isEmpty)
    }

    @Test("compound where renders parenthesized with ordered placeholders")
    func compoundWhere() {
        let statement = SQLRenderer.select(
            Post.where { $0.published == true && $0.viewCount > 100 })
        #expect(statement.sql == #"SELECT \#(allColumns) FROM "hangar_posts" WHERE (("published" = $1) AND ("view_count" > $2))"#)
        #expect(statement.binds.count == 2)
    }

    @Test("chained where calls AND-combine")
    func chainedWhere() {
        var query = Post.where { $0.published }
        query = query.where { $0.viewCount >= 10 }
        let statement = SQLRenderer.select(query)
        #expect(statement.sql.hasSuffix(#"WHERE ("published" AND ("view_count" >= $1))"#))
    }

    @Test("orWhere OR-combines against everything accumulated so far")
    func orWhere() {
        let query = Post.where { $0.published }.orWhere { $0.viewCount > 1000 }
        let statement = SQLRenderer.select(query)
        #expect(statement.sql.hasSuffix(#"WHERE ("published" OR ("view_count" > $1))"#))
    }

    @Test("order, limit, offset")
    func orderLimitOffset() {
        let statement = SQLRenderer.select(
            Post.where { $0.published }
                .order { $0.createdAt.desc() }
                .order { $0.title.asc() }
                .limit(20)
                .offset(40))
        #expect(statement.sql.hasSuffix(#"ORDER BY "created_at" DESC, "title" ASC LIMIT 20 OFFSET 40"#))
    }

    @Test("nil comparison renders IS NULL / IS NOT NULL, never = NULL")
    func nilComparison() {
        #expect(SQLRenderer.select(Post.where { $0.nickname == nil }).sql
            .hasSuffix(#"WHERE ("nickname" IS NULL)"#))
        #expect(SQLRenderer.select(Post.where { $0.nickname != nil }).sql
            .hasSuffix(#"WHERE ("nickname" IS NOT NULL)"#))
        let bound = SQLRenderer.select(Post.where { $0.nickname == "zed" })
        #expect(bound.sql.hasSuffix(#"WHERE ("nickname" = $1)"#))
        #expect(bound.binds.count == 1)
    }

    @Test("negation and ilike")
    func negationAndILike() {
        let statement = SQLRenderer.select(
            Post.where { !$0.published || $0.title.ilike("%hangar%") })
        #expect(statement.sql.hasSuffix(#"WHERE (NOT ("published") OR ("title" ILIKE $1))"#))
    }

    @Test("enum columns compare through a bound parameter")
    func enumComparison() {
        let statement = SQLRenderer.select(Post.where { $0.status == .draft })
        #expect(statement.sql.hasSuffix(#"WHERE ("status" = $1)"#))
        #expect(statement.binds.count == 1)
    }

    @Test("count ignores ordering, limit, and offset")
    func countIgnoresOrderAndLimit() {
        let statement = SQLRenderer.count(
            Post.where { $0.published }.order { $0.createdAt.desc() }.limit(5))
        #expect(statement.sql == #"SELECT count(*) FROM "hangar_posts" WHERE "published""#)
    }

    @Test("exists wraps the predicate in SELECT EXISTS")
    func existsStatement() {
        let statement = SQLRenderer.exists(Post.where { $0.viewCount > 0 })
        #expect(statement.sql == #"SELECT EXISTS (SELECT 1 FROM "hangar_posts" WHERE ("view_count" > $1))"#)
    }

    @Test("insert lists insertable columns and RETURNING lists all")
    func insertStatement() throws {
        let statement = try SQLRenderer.insert(Post.sample())
        #expect(statement.sql == """
            INSERT INTO "hangar_posts" (\(allColumns)) \
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING \(allColumns)
            """)
        #expect(statement.binds.count == 9)
    }

    @Test("a generated key is excluded from INSERT but present in RETURNING")
    func insertSkipsGeneratedKey() throws {
        let statement = try SQLRenderer.insert(Event(name: "deploy"))
        #expect(statement.sql == #"INSERT INTO "hangar_events" ("name") VALUES ($1) RETURNING "id", "name""#)
        #expect(statement.binds.count == 1)
    }

    @Test("update SETs non-key columns and filters by primary key")
    func updateStatement() throws {
        let statement = try SQLRenderer.update(Post.sample())
        #expect(statement.sql == """
            UPDATE "hangar_posts" SET "title" = $1, "published" = $2, "view_count" = $3, \
            "created_at" = $4, "nickname" = $5, "status" = $6, "metadata" = $7, "author_id" = $8 \
            WHERE "id" = $9 RETURNING \(allColumns)
            """)
        #expect(statement.binds.count == 9)
    }

    @Test("delete filters by primary key and RETURNING proves the hit")
    func deleteStatement() throws {
        let statement = try SQLRenderer.delete(Event(id: 7, name: "deploy"))
        #expect(statement.sql == #"DELETE FROM "hangar_events" WHERE "id" = $1 RETURNING "id""#)
        #expect(statement.binds.count == 1)
    }

    @Test("identifiers are quoted with embedded quotes doubled")
    func identifierQuoting() {
        #expect(SQLRenderer.quote("plain") == #""plain""#)
        #expect(SQLRenderer.quote(#"we"ird"#) == #""we""ird""#)
    }
}

@Suite("Schema metadata derived by @Entity")
struct SchemaMetadataTests {

    @Test("schema records names, key, and generated columns")
    func postSchema() {
        #expect(Post.schema.name == "hangar_posts")
        #expect(Post.schema.columns.map(\.name) == [
            "id", "title", "published", "view_count", "created_at",
            "nickname", "status", "metadata", "author_id",
        ])
        #expect(Post.schema.primaryKey.map(\.name) == ["id"])
        #expect(Post.schema.insertable.count == 9)
        #expect(Post.schema.updatable.map(\.name).contains("id") == false)
    }

    @Test("generated key is not insertable but is the key")
    func eventSchema() {
        #expect(Event.schema.primaryKey.map(\.name) == ["id"])
        #expect(Event.schema.insertable.map(\.name) == ["name"])
    }

    @Test("the macro-generated memberwise init survives (defaults included)")
    func memberwiseInit() {
        let event = Event(name: "deploy")
        #expect(event.id == 0)
        let post = Post.sample(nickname: "zed")
        #expect(post.nickname == "zed")
    }

    @Test("NULLS FIRST/LAST renders after the direction, and only when asked")
    func nullsPlacement() {
        // Absent by default: the server's own rule still applies, and the SQL
        // says nothing about it.
        #expect(
            SQLRenderer.select(Post.order { $0.nickname.desc() }).sql
                .hasSuffix(#"ORDER BY "nickname" DESC"#))
        #expect(
            SQLRenderer.select(Post.order { $0.nickname.desc().nullsLast() }).sql
                .hasSuffix(#"ORDER BY "nickname" DESC NULLS LAST"#))
        #expect(
            SQLRenderer.select(Post.order { $0.nickname.asc().nullsFirst() }).sql
                .hasSuffix(#"ORDER BY "nickname" ASC NULLS FIRST"#))
    }
}
