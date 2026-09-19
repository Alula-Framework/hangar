import Foundation
import PropertyBased
import Testing

@testable import Hangar

extension PostgresIntegrationSuite {

    /// Generated predicates, run against Postgres and against an evaluator
    /// written here, compared row for row.
    ///
    /// Every other property in this suite checks the *shape* of the SQL — that
    /// binds are numbered, that clauses appear when asked for. None of them can
    /// tell you the query means what it says. A renderer that emitted `<` for
    /// `>` would satisfy all of them and return the wrong rows forever.
    ///
    /// So this one asks the server. For each generated predicate: run it, and
    /// separately evaluate the same condition over the same rows in Swift. The
    /// two row sets must agree. When they do not, one of the two is wrong and
    /// the failure names the predicate that separates them.
    ///
    /// **The evaluator models SQL's three-valued logic**, because that is where
    /// the disagreements would otherwise be mine rather than the library's.
    /// `nickname = 'alice'` is neither true nor false for a row whose nickname
    /// is NULL — it is unknown, `NOT unknown` is still unknown, and only *true*
    /// returns a row. Getting that wrong in the evaluator would produce
    /// failures that look like renderer bugs and are not.
    @Suite("Differential: generated predicates against the server")
    struct DifferentialPropertyTests {

        /// The condition tree, built from a flat program so it shrinks.
        indirect enum Condition: Sendable {
            case viewCountAbove(Int)
            case published(Bool)
            case nicknameIsNull
            case nicknameIs(String)
            case titleIs(String)
            case not(Condition)
            case and(Condition, Condition)
            case or(Condition, Condition)
        }

        enum Step: Sendable, Equatable {
            case viewCountAbove(Int)
            case published(Bool)
            case nicknameIsNull
            case nicknameIs(String)
            case titleIs(String)
            case not
            case and
            case or
        }

        /// Values come from the same small pools the fixture rows use, so a
        /// generated predicate actually selects something. Drawing view counts
        /// from the whole Int range would generate 300 predicates that match
        /// every row or none, and compare two empty sets forever.
        static let steps = Gen.frequency(
            (
                3,
                Gen.element(of: [0, 10, 50, 100]).map { Step.viewCountAbove($0 ?? 0) }.eraseToAny()
            ),
            (2, Gen.bool.map { Step.published($0) }.eraseToAny()),
            (2, Gen.always(Step.nicknameIsNull).eraseToAny()),
            (
                2,
                Gen.element(of: ["alice", "bob", "carol"])
                    .map { Step.nicknameIs($0 ?? "alice") }.eraseToAny()
            ),
            (
                2,
                Gen.element(of: ["first", "second", "third"])
                    .map { Step.titleIs($0 ?? "first") }.eraseToAny()
            ),
            (2, Gen.always(Step.not).eraseToAny()),
            (2, Gen.always(Step.and).eraseToAny()),
            (2, Gen.always(Step.or).eraseToAny())
        ).array(of: 1...10)

        static func fold(_ steps: [Step]) -> Condition {
            var stack: [Condition] = []
            for step in steps {
                switch step {
                case .viewCountAbove(let count): stack.append(.viewCountAbove(count))
                case .published(let flag): stack.append(.published(flag))
                case .nicknameIsNull: stack.append(.nicknameIsNull)
                case .nicknameIs(let name): stack.append(.nicknameIs(name))
                case .titleIs(let title): stack.append(.titleIs(title))
                case .not: if let top = stack.popLast() { stack.append(.not(top)) }
                case .and:
                    if let right = stack.popLast(), let left = stack.popLast() {
                        stack.append(.and(left, right))
                    }
                case .or:
                    if let right = stack.popLast(), let left = stack.popLast() {
                        stack.append(.or(left, right))
                    }
                }
            }
            return stack.last ?? .published(true)
        }

        static func predicate(_ condition: Condition, _ columns: Post.QueryColumns)
            -> Hangar
            .Predicate
        {
            switch condition {
            case .viewCountAbove(let count): return columns.viewCount > count
            case .published(let flag): return columns.published == flag
            case .nicknameIsNull: return columns.nickname == nil
            case .nicknameIs(let name): return columns.nickname == name
            case .titleIs(let title): return columns.title == title
            case .not(let inner): return !predicate(inner, columns)
            case .and(let left, let right):
                return predicate(left, columns) && predicate(right, columns)
            case .or(let left, let right):
                return predicate(left, columns) || predicate(right, columns)
            }
        }

        /// SQL truth: nil is UNKNOWN, and only `true` returns a row.
        static func evaluate(_ condition: Condition, _ post: Post) -> Bool? {
            switch condition {
            case .viewCountAbove(let count): return post.viewCount > count
            case .published(let flag): return post.published == flag
            case .nicknameIsNull: return post.nickname == nil
            case .nicknameIs(let name):
                guard let nickname = post.nickname else { return nil }  // UNKNOWN
                return nickname == name
            case .titleIs(let title): return post.title == title
            case .not(let inner):
                guard let value = evaluate(inner, post) else { return nil }
                return !value
            case .and(let left, let right):
                let first = evaluate(left, post)
                let second = evaluate(right, post)
                if first == false || second == false { return false }  // FALSE wins
                if first == nil || second == nil { return nil }
                return true
            case .or(let left, let right):
                let first = evaluate(left, post)
                let second = evaluate(right, post)
                if first == true || second == true { return true }  // TRUE wins
                if first == nil || second == nil { return nil }
                return false
            }
        }

        /// Deliberately varied on every column the predicates touch, including
        /// both NULL and non-NULL nicknames so the three-valued paths are live.
        static func fixtures() -> [Post] {
            var posts: [Post] = []
            for (index, title) in ["first", "second", "third"].enumerated() {
                for viewCount in [0, 10, 50, 100] {
                    let nickname: String? =
                        switch (index + viewCount) % 4 {
                        case 0: nil
                        case 1: "alice"
                        case 2: "bob"
                        default: "carol"
                        }
                    posts.append(
                        Post.sample(
                            title: title, published: viewCount % 20 == 0,
                            viewCount: viewCount, nickname: nickname))
                }
            }
            return posts
        }

        @Test("the server and an independent evaluator select the same rows")
        func serverAgreesWithEvaluator() async throws {
            try await withRepo { repo in
                let rows = Self.fixtures()
                for row in rows { _ = try await repo.insert(row) }

                await propertyCheck(count: 120, input: Self.steps) { steps in
                    let condition = Self.fold(steps)
                    let returned = try await repo.all(
                        Post.where { Self.predicate(condition, $0) })
                    let expected = rows.filter { Self.evaluate(condition, $0) == true }
                    #expect(Set(returned.map(\.id)) == Set(expected.map(\.id)))
                }
            }
        }
    }
}
