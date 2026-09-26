import Foundation
import Testing

@testable import Hangar

@Suite("Row-level expressions")
struct ColumnExpressionTests {
    @Test("an assignment from an expression is SQL, with only the operand bound")
    func incrementRenders() throws {
        let statement = try SQLRenderer.update(
            Post.where { $0.title == "x" },
            set: [
                Post.queryColumns.viewCount.set(to: Post.queryColumns.viewCount.adding(1))._assignment,
            ])
        #expect(statement.sql.contains(#"SET "view_count" = ("view_count" + $"#), "\(statement.sql)")
        #expect(statement.binds.count == 2)
    }

    @Test("the transaction timestamp is the server's clock")
    func nowRenders() throws {
        let statement = try SQLRenderer.update(
            Post.all, set: [Post.queryColumns.createdAt.set(to: .transactionTimestamp)._assignment])
        #expect(statement.sql.contains(#""created_at" = now()"#), "\(statement.sql)")
    }

    @Test("expressions compare in where and select")
    func whereAndSelect() throws {
        let statement = SQLRenderer.select(Post.where { $0.viewCount.multiplied(by: 2) > 10 })
        #expect(statement.sql.hasSuffix(#"WHERE (("view_count" * $1) > $2)"#), "\(statement.sql)")
    }

    @Test("swift arithmetic is unaffected")
    func plainArithmetic() {
        let a = 3, b = 4.5
        #expect(a + 1 == 4)
        #expect(b * 2 == 9)
        #expect(Date(timeIntervalSince1970: 0) + 1 == Date(timeIntervalSince1970: 1))
    }
}
