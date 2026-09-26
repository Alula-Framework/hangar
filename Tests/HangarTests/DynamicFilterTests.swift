import Foundation
import Testing

@testable import Hangar

// Phase 5: allowlisted dynamic filters. The unit suite pins
// the safety properties; the integration suite proves the round trip.

@Suite("Dynamic filters — the allowlist")
struct DynamicFilterTests {

    @Test("allowlisted fields become bound equality predicates, in sorted order")
    func allowlistedFields() throws {
        let statement = SQLRenderer.select(
            try Post.where(dynamic: ["view_count": 10, "published": true, "title": "x"]))
        #expect(statement.sql.hasSuffix(
            #"WHERE ((("published" = $1) AND ("title" = $2)) AND ("view_count" = $3))"#))
        #expect(statement.binds.count == 3)
    }

    @Test("a field outside the allowlist is rejected, never interpolated")
    func unknownField() {
        do {
            _ = try Post.where(dynamic: ["author_id": "5e8f..."])
            Issue.record("expected unknownFilterField")
        } catch let HangarError.unknownFilterField(table, field) {
            #expect(table == "hangar_posts")
            #expect(field == "author_id")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a hostile field name cannot reach SQL")
    func hostileFieldName() {
        #expect(throws: HangarError.self) {
            _ = try Post.where(dynamic: [#"title" OR 1=1 --"#: "x"])
        }
    }

    @Test("a value whose shape doesn't match the column is rejected")
    func typeMismatch() {
        #expect(throws: HangarError.self) {
            _ = try Post.where(dynamic: ["view_count": "not a number"])
        }
        #expect(throws: HangarError.self) {
            _ = try Post.where(dynamic: ["published": 1])
        }
    }

    @Test("smallint, integer and bigint columns filter; an out-of-range value is a mismatch")
    func fixedWidthIntegers() throws {
        let statement = SQLRenderer.select(
            try TypeRow.where(dynamic: ["small": 3, "medium": 70_000, "large": 5_000_000_000]))
        #expect(statement.sql.hasSuffix(
            #"WHERE ((("large" = $1) AND ("medium" = $2)) AND ("small" = $3))"#))
        #expect(throws: HangarError.self) { _ = try TypeRow.where(dynamic: ["small": 70_000]) }
        #expect(throws: HangarError.self) { _ = try TypeRow.where(dynamic: ["medium": 5_000_000_000]) }
        #expect(throws: HangarError.self) { _ = try TypeRow.where(dynamic: ["small": "3"]) }
        #expect(Int16.fromDynamicFilter(.int(Int(Int16.min))) == .min)
    }

    @Test("null filters optional columns as IS NULL; non-optional rejects it")
    func nullHandling() throws {
        let statement = SQLRenderer.select(try Post.where(dynamic: ["nickname": nil]))
        #expect(statement.sql.hasSuffix(#"WHERE ("nickname" IS NULL)"#))
        #expect(throws: HangarError.self) {
            _ = try Post.where(dynamic: ["title": nil])
        }
    }

    @Test("enum columns filter by label through the one-line opt-in")
    func enumFilter() throws {
        let statement = SQLRenderer.select(try Post.where(dynamic: ["status": "draft"]))
        #expect(statement.sql.hasSuffix(#"WHERE ("status" = $1)"#))
        #expect(throws: HangarError.self) {
            _ = try Post.where(dynamic: ["status": "no_such_label"])
        }
    }

    @Test("dynamic filters compose onto an existing compile-checked query")
    func composesWithStaticWhere() throws {
        let statement = SQLRenderer.select(
            try Post.where { $0.viewCount > 5 }.where(dynamic: ["published": true]))
        #expect(statement.sql.hasSuffix(#"WHERE (("view_count" > $1) AND ("published" = $2))"#))
    }

    @Test("[String: DynamicFilterValue] decodes straight from a JSON body")
    func decodesFromJSON() throws {
        let json = #"{"title": "hello", "published": true, "view_count": 3, "nickname": null}"#
        let filters = try JSONDecoder().decode(
            [String: DynamicFilterValue].self, from: Data(json.utf8))
        #expect(filters["title"] == .string("hello"))
        #expect(filters["published"] == .bool(true))
        #expect(filters["view_count"] == .int(3))
        #expect(filters["nickname"] == .null)
    }
}

@Suite("SQL fragments — the safe escape hatch")
struct SQLFragmentTests {

    @Test("literals are SQL, interpolated values are binds — never text")
    func valuesBecomeBinds() {
        let statement = SQLRenderer.select(
            Post.where { p in
                p.published && SQLFragment("char_length(\(p.title)) > \(3)")
            })
        #expect(statement.sql.hasSuffix(#"WHERE ("published" AND (char_length("title") > $1))"#))
        #expect(statement.binds.count == 1)
        #expect(!statement.sql.contains("3"))
    }

    @Test("string values cannot leak into SQL through interpolation")
    func noLeakage() {
        let hostile = "'; DROP TABLE hangar_posts; --"
        let statement = SQLRenderer.select(
            Post.where { _ in SQLFragment("\(hostile) = \(hostile)") as SQLFragment })
        #expect(statement.sql.hasSuffix("WHERE ($1 = $2)"))
        #expect(!statement.sql.contains("DROP TABLE"))
    }

    @Test("raw: is verbatim — the loud, deliberate hole")
    func rawIsVerbatim() {
        let statement = SQLRenderer.select(
            Post.where { _ in SQLFragment("\(raw: "1 = 1")") as SQLFragment })
        #expect(statement.sql.hasSuffix("WHERE (1 = 1)"))
    }

    @Test("a fragment works as a typed SELECT expression")
    func fragmentExpression() {
        let statement = SQLRenderer.select(
            Post.select { p in SQLFragment("char_length(\(p.title))").expression(as: Int.self) })
        #expect(statement.sql == #"SELECT (char_length("title")) FROM "hangar_posts""#)
    }
}

extension TypeRow: DynamicallyFilterable {
    static let filterable: [String: AnyColumn<TypeRow>] = [
        "small": .init(\.small),
        "medium": .init(\.medium),
        "large": .init(\.large),
    ]
}
