import Foundation
import PostgresNIO
import PropertyBased
import Testing

@testable import Hangar

extension PostgresIntegrationSuite {

    /// Properties written to break the library rather than to describe it.
    ///
    /// The existing property tests all ask whether a *select* is built the way
    /// it was asked for. An external audit of 0.7.0/0.8.0 found two defects
    /// they could not have caught — a bulk delete over a set operation that
    /// rendered `DELETE FROM "posts"` with no WHERE, and a projection that
    /// silently dropped a UNION — because both are about what happens to a
    /// query *after* it is built, and neither is a select.
    ///
    /// So these take the opposite posture. Rather than "does this render as
    /// intended", they ask what the server thinks of everything the builder
    /// can produce, and whether the dangerous paths stay faithful to the query
    /// they came from.
    @Suite("Adversarial: what the builder can produce")
    struct AdversarialPropertyTests {

        // MARK: Generated query programs

        /// One builder step. Deliberately includes the combinations that have
        /// gone wrong: set operations, CTEs, windows, grouping, scoping.
        enum Step: Sendable, Equatable {
            case filterViews(Int)
            case filterTitle(String)
            case filterPublished(Bool)
            case filterNicknameIsNull
            case order
            case orderNullsLast
            case limit(Int)
            case offset(Int)
            case distinct
            case unionWithFiltered(Int)
            case intersectWithFiltered(Int)
            case exceptWithFiltered(Int)
            case attachCTE(Int)
            case readFromCTE(Int)
            case withDeletedRows
            case onlyDeletedRows
        }

        static let steps = Gen.frequency(
            (4, Gen.int(in: 0...5_000).map { Step.filterViews($0) }.eraseToAny()),
            (2, Gen.int(in: 0...99).map { Step.filterTitle("SENTINEL-\($0)") }.eraseToAny()),
            (2, Gen.bool.map { Step.filterPublished($0) }.eraseToAny()),
            (1, Gen.always(Step.filterNicknameIsNull).eraseToAny()),
            (2, Gen.always(Step.order).eraseToAny()),
            (1, Gen.always(Step.orderNullsLast).eraseToAny()),
            (2, Gen.int(in: 1...50).map { Step.limit($0) }.eraseToAny()),
            (1, Gen.int(in: 0...20).map { Step.offset($0) }.eraseToAny()),
            (1, Gen.always(Step.distinct).eraseToAny()),
            (2, Gen.int(in: 0...5_000).map { Step.unionWithFiltered($0) }.eraseToAny()),
            (1, Gen.int(in: 0...5_000).map { Step.intersectWithFiltered($0) }.eraseToAny()),
            (1, Gen.int(in: 0...5_000).map { Step.exceptWithFiltered($0) }.eraseToAny()),
            (2, Gen.int(in: 0...3).map { Step.attachCTE($0) }.eraseToAny()),
            (1, Gen.int(in: 0...3).map { Step.readFromCTE($0) }.eraseToAny())
        ).array(of: 0...10)

        /// Folds a program into a query. Every step is legal on its own; the
        /// interesting part is what their combinations render to.
        static func build(_ steps: [Step]) -> Query<Post, Post> {
            var query = Post.all
            for step in steps {
                switch step {
                case .filterViews(let n): query = query.where { $0.viewCount > n }
                case .filterTitle(let t): query = query.where { $0.title == t }
                case .filterPublished(let f): query = query.where { $0.published == f }
                case .filterNicknameIsNull: query = query.where { $0.nickname == nil }
                case .order: query = query.order { $0.viewCount.desc() }
                case .orderNullsLast: query = query.order { $0.nickname.asc().nullsLast() }
                case .limit(let n): query = query.limit(n)
                case .offset(let n): query = query.offset(n)
                case .distinct: query = query.distinct()
                case .unionWithFiltered(let n):
                    query = query.union(Post.where { $0.viewCount > n })
                case .intersectWithFiltered(let n):
                    query = query.intersect(Post.where { $0.viewCount > n })
                case .exceptWithFiltered(let n):
                    query = query.except(Post.where { $0.viewCount > n })
                case .attachCTE(let index):
                    query = query.with(
                        CommonTable<Post>("cte_\(index)").where { $0.viewCount > index })
                case .readFromCTE(let index):
                    query = query.with(
                        CommonTable<Post>("cte_\(index)").where { $0.viewCount > index })
                    query = query.reading(from: "cte_\(index)")
                case .withDeletedRows, .onlyDeletedRows:
                    break  // soft delete lives on a different entity
                }
            }
            return query
        }

        // MARK: The properties

        @Test("the server parses everything the builder can produce")
        func postgresParsesIt() async throws {
            try await withRepo { repo in
                await propertyCheck(count: 250, input: Self.steps) { steps in
                    let query = Self.build(steps)
                    // PREPARE rather than execute: this asks whether the
                    // statement is well-formed and well-typed, which is the
                    // question, without depending on any rows existing. Three
                    // shipped bugs — a cast outside its window, lag's bigint
                    // offset, an unqualified ON in a recursive step — rendered
                    // plausibly and failed exactly here.
                    let rendered = try query.renderedQuery()
                    let name = "adversarial_\(abs(rendered.sql.hashValue))"
                    var sql = rendered.sql
                    // `$n` placeholders are already in the text; PREPARE wants
                    // the types, which Postgres infers.
                    sql = "PREPARE \(name) AS \(sql)"
                    do {
                        _ = try await repo.execute(SQLFragment(stringLiteral: sql))
                        _ = try await repo.execute(
                            SQLFragment(stringLiteral: "DEALLOCATE \(name)"))
                    } catch {
                        Issue.record("Postgres refused a query the builder produced: \(error)")
                    }
                }
            }
        }

        @Test("a bulk write is refused, or targets exactly what the query selects")
        func bulkWritesStayFaithful() async {
            await propertyCheck(count: 300, input: Self.steps) { steps in
                let query = Self.build(steps)
                let selectSQL = SQLRenderer.select(query).sql

                // Either the write refuses the query, or its WHERE is the
                // query's WHERE. Anything else is a statement that touches
                // rows the caller did not describe — which is how
                // `delete(a.union(b))` became `DELETE FROM "posts"`.
                guard let deleteSQL = try? query.debugDeleteSQL() else { return }

                let selectWhere = Self.whereClause(of: selectSQL)
                let deleteWhere = Self.whereClause(of: deleteSQL)
                #expect(
                    selectWhere == deleteWhere,
                    "delete targets a different set than the query selects")

                // A CTE may *feed* a bulk write, which is supported. What it
                // may not do is be the target, or bring a combination with it.
                #expect(!Self.body(of: deleteSQL).contains(" UNION "))
                #expect(Self.body(of: deleteSQL).hasPrefix("DELETE FROM"))
            }
        }

        @Test("no generated value ever reaches the SQL text")
        func nothingIsInterpolated() async {
            await propertyCheck(count: 300, input: Self.steps) { steps in
                let query = Self.build(steps)
                // Across every statement kind the query can render to, not
                // only the select.
                #expect(!SQLRenderer.select(query).sql.contains("SENTINEL-"))
                #expect(!SQLRenderer.count(query).sql.contains("SENTINEL-"))
                #expect(!SQLRenderer.exists(query).sql.contains("SENTINEL-"))
                if let deleteSQL = try? query.debugDeleteSQL() {
                    #expect(!deleteSQL.contains("SENTINEL-"))
                }
            }
        }

        @Test("every WITH list names each CTE once")
        func cteNamesAreUnique() async {
            await propertyCheck(count: 300, input: Self.steps) { steps in
                let sql = SQLRenderer.select(Self.build(steps)).sql
                let names = Self.declaredCTEs(in: sql)
                #expect(names.count == Set(names).count, "a CTE was declared twice")
            }
        }

        @Test("rendering is deterministic")
        func renderingIsStable() async {
            await propertyCheck(count: 200, input: Self.steps) { steps in
                // Two builds of the same program must be the same statement.
                // A generated name, a dictionary iteration order or a captured
                // counter leaking into the text shows up here and nowhere else.
                #expect(
                    SQLRenderer.select(Self.build(steps)).sql
                        == SQLRenderer.select(Self.build(steps)).sql)
            }
        }

        /// The statement with any `WITH …` prefix removed.
        ///
        /// By paren depth, not by searching for text: a CTE body contains its
        /// own WHERE and its own SELECT, and the first version of this helper
        /// found those and reported two faithful statements as divergent. The
        /// test was wrong, not the renderer.
        static func body(of sql: String) -> String {
            guard sql.hasPrefix("WITH ") else { return sql }
            var depth = 0
            var index = sql.startIndex
            while index < sql.endIndex {
                let character = sql[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        // End of one CTE body. The next thing is either `, `
                        // for another, or the statement itself.
                        let after = sql.index(after: index)
                        let rest = sql[after...].drop(while: { $0 == " " })
                        if rest.hasPrefix(",") {
                            index = rest.index(after: rest.startIndex)
                            continue
                        }
                        return String(rest)
                    }
                }
                index = sql.index(after: index)
            }
            return sql
        }

        /// The `WHERE …` of a statement's own body, up to the clause after it.
        static func whereClause(of sql: String) -> String {
            let statement = body(of: sql)
            guard let start = statement.range(of: " WHERE ") else { return "" }
            let rest = statement[start.upperBound...]
            for terminator in [" ORDER BY ", " LIMIT ", " OFFSET ", " RETURNING ", " GROUP BY "] {
                if let end = rest.range(of: terminator) {
                    return String(rest[..<end.lowerBound])
                }
            }
            return String(rest)
        }

        /// The names a `WITH` list declares, in order.
        static func declaredCTEs(in sql: String) -> [String] {
            guard sql.hasPrefix("WITH ") else { return [] }
            var names: [String] = []
            var rest = Substring(sql.dropFirst("WITH ".count))
            if rest.hasPrefix("RECURSIVE ") { rest = rest.dropFirst("RECURSIVE ".count) }
            while rest.hasPrefix("\"") {
                let after = rest.index(after: rest.startIndex)
                guard let close = rest[after...].firstIndex(of: "\"") else { break }
                names.append(String(rest[after..<close]))
                // Skip this CTE's body by paren depth.
                var depth = 0
                var index = close
                while index < rest.endIndex {
                    if rest[index] == "(" { depth += 1 }
                    if rest[index] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    index = rest.index(after: index)
                }
                guard index < rest.endIndex else { break }
                rest = rest[rest.index(after: index)...].drop(while: { $0 == " " })
                if rest.hasPrefix(",") {
                    rest = rest.dropFirst().drop(while: { $0 == " " })
                } else {
                    break
                }
            }
            return names
        }
    }
}
