import Foundation
import PropertyBased
import Testing

@testable import Hangar

/// Properties of the *builder*, across every statement kind a query renders to.
///
/// `RendererPropertyTests` stresses predicate shape. This stresses the clauses
/// wrapped around it — limit, offset, ordering, distinct — and the fact that
/// one query object renders four different ways. A `Query` is not a string; it
/// is a value that `select`, `count`, `exists` and the bulk writers each read
/// differently, and each of those readers has its own chance to drop a clause,
/// double-count a bind, or keep one that changes the answer.
///
/// Generated input is a flat array of builder operations, for the same reason
/// the predicate tests generate a program: arrays shrink, so a counterexample
/// comes back as the two operations that still break the law.
@Suite("Query builder properties")
struct QueryBuilderPropertyTests {

    /// One builder call. `where` accumulates; the rest are last-call-wins,
    /// which is itself one of the properties below.
    enum Operation: Sendable, Equatable {
        case whereViewCountAbove(Int)
        case whereTitleIs(String)
        case wherePublished(Bool)
        case limit(Int)
        case offset(Int)
        case orderViewCountDescending
        case orderTitleAscending
        case orderNicknameAscendingNullsFirst
        case distinct
    }

    static let operations = Gen.frequency(
        (3, Gen.int(in: 0...10_000).map { Operation.whereViewCountAbove($0) }.eraseToAny()),
        (2, Gen.int(in: 0...9_999).map { Operation.whereTitleIs("SENTINEL-\($0)") }.eraseToAny()),
        (2, Gen.bool.map { Operation.wherePublished($0) }.eraseToAny()),
        (2, Gen.int(in: 1...500).map { Operation.limit($0) }.eraseToAny()),
        (2, Gen.int(in: 0...500).map { Operation.offset($0) }.eraseToAny()),
        (2, Gen.always(Operation.orderViewCountDescending).eraseToAny()),
        (2, Gen.always(Operation.orderTitleAscending).eraseToAny()),
        (1, Gen.always(Operation.orderNicknameAscendingNullsFirst).eraseToAny()),
        (1, Gen.always(Operation.distinct).eraseToAny())
    ).array(of: 0...12)

    static func build(_ operations: [Operation]) -> Query<Post, Post> {
        var query = Post.all
        for operation in operations {
            switch operation {
            case .whereViewCountAbove(let count): query = query.where { $0.viewCount > count }
            case .whereTitleIs(let title): query = query.where { $0.title == title }
            case .wherePublished(let flag): query = query.where { $0.published == flag }
            case .limit(let count): query = query.limit(count)
            case .offset(let count): query = query.offset(count)
            case .orderViewCountDescending: query = query.order { $0.viewCount.desc() }
            case .orderTitleAscending: query = query.order { $0.title.asc() }
            case .orderNicknameAscendingNullsFirst:
                query = query.order { $0.nickname.asc().nullsFirst() }
            case .distinct: query = query.distinct()
            }
        }
        return query
    }

    /// `$1, $2, …` in the order the text carries them.
    static func placeholders(in sql: String) -> [Int] {
        var found: [Int] = []
        var digits = ""
        var reading = false
        for character in sql {
            if character == "$" {
                reading = true
                digits = ""
            } else if reading, character.isNumber {
                digits.append(character)
            } else if reading {
                if let value = Int(digits) { found.append(value) }
                reading = false
            }
        }
        if reading, let value = Int(digits) { found.append(value) }
        return found
    }

    static func isWellBound(_ statement: RenderedStatement) -> Bool {
        let found = placeholders(in: statement.sql)
        guard found.count == statement.binds.count else { return false }
        return found == Array(1...max(statement.binds.count, 1)).prefix(found.count).map { $0 }
    }

    @Test("every statement kind binds what it references, and only that")
    func allStatementKindsAreWellBound() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let query = Self.build(operations)
            // One query value, four readers. Each keeps its own BindWriter, so
            // each is its own chance to mis-number.
            #expect(Self.isWellBound(SQLRenderer.select(query)))
            #expect(Self.isWellBound(SQLRenderer.count(query)))
            #expect(Self.isWellBound(SQLRenderer.exists(query)))
        }
    }

    @Test("no bound value reaches the text of any statement kind")
    func nothingIsInterpolated() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let query = Self.build(operations)
            #expect(!SQLRenderer.select(query).sql.contains("SENTINEL-"))
            #expect(!SQLRenderer.count(query).sql.contains("SENTINEL-"))
            #expect(!SQLRenderer.exists(query).sql.contains("SENTINEL-"))
        }
    }

    @Test("limit and offset are last-call-wins, and absent when never called")
    func limitAndOffsetAreLastCallWins() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let sql = SQLRenderer.select(Self.build(operations)).sql
            let lastLimit = operations.compactMap { operation -> Int? in
                if case .limit(let count) = operation { return count }
                return nil
            }.last
            let lastOffset = operations.compactMap { operation -> Int? in
                if case .offset(let count) = operation { return count }
                return nil
            }.last

            if let lastLimit {
                #expect(sql.contains(" LIMIT \(lastLimit)"))
            } else {
                #expect(!sql.contains(" LIMIT "))
            }
            if let lastOffset {
                #expect(sql.contains(" OFFSET \(lastOffset)"))
            } else {
                #expect(!sql.contains(" OFFSET "))
            }
        }
    }

    @Test("count and exists drop the clauses that would change their answer")
    func countAndExistsStripOrderingAndPaging() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let query = Self.build(operations)
            let counted = SQLRenderer.count(query).sql
            let existed = SQLRenderer.exists(query).sql
            // "How many match" and "is there one" are not page questions, and
            // ORDER BY is rejected outright in the EXISTS position. A clause
            // leaking through here is a wrong answer, not an untidy string.
            #expect(!counted.contains(" ORDER BY "))
            #expect(!existed.contains(" ORDER BY "))
            #expect(!existed.contains(" LIMIT "))
            #expect(!existed.contains(" OFFSET "))
        }
    }

    @Test("every ordering call contributes exactly one term, in call order")
    func orderingsAccumulateInOrder() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let sql = SQLRenderer.select(Self.build(operations)).sql
            let expected = operations.compactMap { operation -> String? in
                switch operation {
                case .orderViewCountDescending: return #""view_count" DESC"#
                case .orderTitleAscending: return #""title" ASC"#
                case .orderNicknameAscendingNullsFirst: return #""nickname" ASC NULLS FIRST"#
                default: return nil
                }
            }
            guard !expected.isEmpty else {
                #expect(!sql.contains(" ORDER BY "))
                return
            }
            #expect(sql.contains(" ORDER BY " + expected.joined(separator: ", ")))
        }
    }

    @Test("a WHERE is present exactly when a predicate was asked for")
    func whereTracksThePredicate() async {
        await propertyCheck(count: 300, input: Self.operations) { operations in
            let sql = SQLRenderer.select(Self.build(operations)).sql
            let predicated = operations.contains { operation in
                switch operation {
                case .whereViewCountAbove, .whereTitleIs, .wherePublished: return true
                default: return false
                }
            }
            #expect(sql.contains(" WHERE ") == predicated)
        }
    }
}
