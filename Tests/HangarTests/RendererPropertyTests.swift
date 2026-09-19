import Foundation
import Testing

@testable import Hangar

/// Properties of the renderer, checked over generated predicate trees.
///
/// The rest of `RendererTests` is example-based: one hand-written query, one
/// expected SQL string. That is the right shape for "does this clause read the
/// way we intended", and it is a poor shape for the invariants that have to
/// hold across *every* shape a predicate can take — placeholder numbering in
/// particular, which is bookkeeping threaded through nested rendering and is
/// exactly the sort of thing that survives every example someone thought to
/// write and breaks on the tree they did not.
///
/// Generation is seeded and the seed is printed on failure, so a counterexample
/// is reproducible rather than a story about a flake.
@Suite("Renderer properties")
struct RendererPropertyTests {

    /// Deterministic, so a failing case can be replayed from its seed alone.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) {
            state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// A random predicate tree over `Post`, `depth` levels deep.
    ///
    /// Leaves bind a value; branches combine. Every string leaf carries a
    /// sentinel so the "no user value reaches the SQL text" property below has
    /// something unmistakable to look for.
    static func predicate(
        _ columns: Post.QueryColumns, depth: Int, rng: inout SeededGenerator
    ) -> Hangar.Predicate {
        if depth <= 0 {
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: return columns.viewCount > Int.random(in: 0...10_000, using: &rng)
            case 1: return columns.viewCount <= Int.random(in: 0...10_000, using: &rng)
            case 2: return columns.published == Bool.random(using: &rng)
            case 3: return columns.title == "SENTINEL-\(UInt16.random(in: 0...9999, using: &rng))"
            case 4: return columns.nickname == nil
            default: return columns.status == .published
            }
        }
        let left = predicate(columns, depth: depth - 1, rng: &rng)
        let right = predicate(columns, depth: depth - 1, rng: &rng)
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: return left && right
        case 1: return left || right
        default: return !left
        }
    }

    /// `$1, $2, …` in the order they appear in the SQL text.
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
                if let n = Int(digits) { found.append(n) }
                reading = false
            }
        }
        if reading, let n = Int(digits) { found.append(n) }
        return found
    }

    @Test("every placeholder is numbered 1...n, in order, once, and matches the bind count")
    func placeholderNumbering() {
        for seed in UInt64(1)...400 {
            var rng = SeededGenerator(seed: seed)
            let depth = Int.random(in: 0...4, using: &rng)
            let statement = SQLRenderer.select(
                Post.where { Self.predicate($0, depth: depth, rng: &rng) })
            let found = Self.placeholders(in: statement.sql)

            // The contract `RenderedStatement` states: binds are "in
            // placeholder order". If that is true, the numbers the SQL carries
            // are exactly 1...binds.count, ascending, each once.
            #expect(
                found == Array(1...max(statement.binds.count, 1)).prefix(found.count).map { $0 },
                "seed \(seed): placeholders \(found) for \(statement.binds.count) binds")
            let mismatch: String =
                "seed \(seed): \(found.count) placeholders, \(statement.binds.count) binds — "
                + "a mismatch is a bind sent to the wrong column, or none"
            #expect(found.count == statement.binds.count, Testing.Comment(rawValue: mismatch))
        }
    }

    @Test("no bound value ever reaches the SQL text")
    func valuesNeverInterpolated() {
        for seed in UInt64(1)...400 {
            var rng = SeededGenerator(seed: seed)
            let depth = Int.random(in: 0...4, using: &rng)
            let statement = SQLRenderer.select(
                Post.where { Self.predicate($0, depth: depth, rng: &rng) })
            // Every generated string leaf is a sentinel; if one appears in the
            // text, a value was interpolated rather than bound, and that is the
            // injection seam.
            #expect(
                !statement.sql.contains("SENTINEL-"),
                "seed \(seed): a bound value was interpolated into the SQL")
        }
    }

    @Test("parentheses are balanced however the tree nests")
    func parenthesesBalance() {
        for seed in UInt64(1)...400 {
            var rng = SeededGenerator(seed: seed)
            let depth = Int.random(in: 0...5, using: &rng)
            let statement = SQLRenderer.select(
                Post.where { Self.predicate($0, depth: depth, rng: &rng) })
            var open = 0
            for character in statement.sql {
                if character == "(" { open += 1 }
                if character == ")" { open -= 1 }
                if open < 0 { break }
            }
            let message: String = "seed \(seed): unbalanced parentheses in \(statement.sql)"
            #expect(open == 0, Testing.Comment(rawValue: message))
        }
    }
}
