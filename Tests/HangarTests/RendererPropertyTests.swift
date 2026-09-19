import Foundation
import PropertyBased
import Testing

@testable import Hangar

/// Properties of the renderer, checked over generated predicate trees.
///
/// The rest of `RendererTests` is example-based: one hand-written query, one
/// expected SQL string. That is the right shape for "does this clause read the
/// way we intended", and a poor one for the invariants that must hold across
/// *every* shape a predicate can take — placeholder numbering in particular,
/// which is bookkeeping threaded through nested rendering and is exactly the
/// sort of thing that survives every example someone thought to write and
/// breaks on the tree they did not.
///
/// **Why the input is a flat array rather than a tree.** These generators feed
/// a list of stack operations that folds into a predicate, instead of building
/// a recursive enum directly. Both produce the same trees; only the first one
/// *shrinks*. Shrinking a generated recursive enum reduced the leaf values and
/// left the shape alone — an eleven-node tree with zeros in it. Shrinking the
/// array removes operations too, so a counterexample arrives as a few steps
/// you can read rather than a shape you have to draw.
///
/// A failure prints a `.fixedSeed(…)` line; adding it to the `@Test` replays
/// that exact case rather than hoping the same tree comes up again.
@Suite("Renderer properties")
struct RendererPropertyTests {

    /// One step of a stack program that builds a predicate.
    ///
    /// Flat on purpose — see the note above. `wrapNot`, `and` and `or` are
    /// no-ops when the stack is too short, which keeps every generated array
    /// valid and means the shrinker never has to preserve a nesting rule.
    enum Step: Sendable {
        case viewCountAbove(Int)
        case published(Bool)
        case titleIs(String)
        case nicknameIsNull
        case statusIsPublished
        case wrapNot
        case and
        case or
    }

    /// Folds the program into a predicate. The sentinel in `titleIs` is what
    /// the "values never reach the SQL" property looks for.
    static func fold(_ steps: [Step], _ columns: Post.QueryColumns) -> Hangar.Predicate {
        var stack: [Hangar.Predicate] = []
        for step in steps {
            switch step {
            case .viewCountAbove(let count): stack.append(columns.viewCount > count)
            case .published(let flag): stack.append(columns.published == flag)
            case .titleIs(let title): stack.append(columns.title == title)
            case .nicknameIsNull: stack.append(columns.nickname == nil)
            case .statusIsPublished: stack.append(columns.status == .published)
            case .wrapNot: if let top = stack.popLast() { stack.append(!top) }
            case .and:
                if let right = stack.popLast(), let left = stack.popLast() {
                    stack.append(left && right)
                }
            case .or:
                if let right = stack.popLast(), let left = stack.popLast() {
                    stack.append(left || right)
                }
            }
        }
        return stack.last ?? (columns.published == true)
    }

    static let steps = Gen.frequency(
        (3, Gen.int(in: 0...10_000).map { Step.viewCountAbove($0) }.eraseToAny()),
        (2, Gen.bool.map { Step.published($0) }.eraseToAny()),
        (2, Gen.int(in: 0...9_999).map { Step.titleIs("SENTINEL-\($0)") }.eraseToAny()),
        (1, Gen.always(Step.nicknameIsNull).eraseToAny()),
        (1, Gen.always(Step.statusIsPublished).eraseToAny()),
        (2, Gen.always(Step.wrapNot).eraseToAny()),
        (2, Gen.always(Step.and).eraseToAny()),
        (2, Gen.always(Step.or).eraseToAny())
    ).array(of: 1...14)

    /// `$1, $2, …` in the order the SQL text carries them.
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

    @Test("placeholders are 1...n, in order, and match the bind count")
    func placeholderNumbering() async {
        await propertyCheck(count: 300, input: Self.steps) { steps in
            let statement = SQLRenderer.select(Post.where { Self.fold(steps, $0) })
            let found = Self.placeholders(in: statement.sql)
            // `RenderedStatement` promises binds "in placeholder order". If
            // that holds, the numbers in the text are exactly 1...binds.count.
            let expected = Array(1...max(statement.binds.count, 1)).prefix(found.count)
            #expect(found == Array(expected))
            // A count mismatch is a bind sent to the wrong column, or none.
            #expect(found.count == statement.binds.count)
        }
    }

    @Test("no bound value ever reaches the SQL text")
    func valuesNeverInterpolated() async {
        await propertyCheck(count: 300, input: Self.steps) { steps in
            let statement = SQLRenderer.select(Post.where { Self.fold(steps, $0) })
            // Every generated title is a sentinel. If one appears in the text,
            // a value was interpolated rather than bound — the injection seam.
            #expect(!statement.sql.contains("SENTINEL-"))
        }
    }

    @Test("parentheses balance however the tree nests")
    func parenthesesBalance() async {
        await propertyCheck(count: 300, input: Self.steps) { steps in
            let statement = SQLRenderer.select(Post.where { Self.fold(steps, $0) })
            var open = 0
            for character in statement.sql {
                if character == "(" { open += 1 }
                if character == ")" { open -= 1 }
                if open < 0 { break }
            }
            #expect(open == 0)
        }
    }
}
