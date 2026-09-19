import Foundation
import Testing

@testable import Hangar

@Suite("Recursive CTE — rendering")
struct RecursiveCTERenderingTests {

    @Test("the step joins the CTE by name, not the entity's table")
    func stepJoinsTheCTE() {
        let tree = CommonTable<Node>("tree")
        let sql = SQLRenderer.select(
            Node.all
                .withRecursive(tree, anchor: Node.where { $0.parentID == nil }) { found in
                    Node.join(found, on: { child, parent in child.parentID == parent.id })
                }
                .reading(from: tree)
        ).sql

        #expect(sql.hasPrefix(#"WITH RECURSIVE "tree" AS ("#))
        #expect(sql.contains(" UNION ALL "))
        // The join target is the CTE. An alias would have rendered
        // `"hangar_posts" AS "tree"`, which is the table, not the CTE.
        #expect(sql.contains(#"JOIN "tree" ON"#))
        #expect(!sql.contains(#""hangar_nodes" AS "tree""#))
        // And the statement reads the CTE back as the entity.
        #expect(sql.contains(#"FROM "tree" AS "hangar_nodes""#))
    }

    @Test("a CTE join qualifies each side with its own name")
    func columnsQualify() {
        let tree = CommonTable<Node>("tree")
        let joined = Node.join(tree, on: { child, parent in child.parentID == parent.id })
        let sql = try! SQLRenderer.select(joined).sql
        #expect(sql.contains(#"ON ("hangar_nodes"."parent_id" = "tree"."id")"#))
    }

    @Test("both halves select the same column list, which UNION ALL requires")
    func halvesMatch() {
        let tree = CommonTable<Node>("tree")
        let sql = SQLRenderer.select(
            Node.all
                .withRecursive(tree, anchor: Node.where { $0.parentID == nil }) { found in
                    Node.join(found, on: { child, parent in child.parentID == parent.id })
                }
                .reading(from: tree)
        ).sql
        let halves = sql.components(separatedBy: " UNION ALL ")
        #expect(halves.count == 2)
        // Same number of selected columns on each side.
        func columnCount(_ half: String) -> Int {
            guard let from = half.range(of: " FROM ") else { return -1 }
            return half[..<from.lowerBound].components(separatedBy: ", ").count
        }
        #expect(columnCount(halves[0]) == columnCount(halves[1]))
    }
}

extension PostgresIntegrationSuite {

    /// A recursive CTE against a real server.
    ///
    /// Rendering `WITH RECURSIVE` proves nothing about whether it terminates
    /// or finds the right rows. This walks a real tree and checks the set it
    /// comes back with — a step that failed to reference the CTE would either
    /// error or return only the anchor.
    @Suite("Recursive CTE (real Postgres)")
    struct RecursiveCTEIntegrationTests {

        @Test("a self-referencing walk collects the whole subtree")
        func walksTheTree() async throws {
            try await withRepo { repo in
                // A chain: root <- middle <- leaf, plus an unrelated row.
                let root = try await repo.insert(Node(id: UUID(), name: "root", parentID: nil))
                let middle = try await repo.insert(
                    Node(id: UUID(), name: "middle", parentID: root.id))
                _ = try await repo.insert(Node(id: UUID(), name: "leaf", parentID: middle.id))
                _ = try await repo.insert(Node(id: UUID(), name: "elsewhere", parentID: nil))

                let tree = CommonTable<Node>("tree")
                let rows = try await repo.all(
                    Node.all
                        .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
                            Node.join(found, on: { child, parent in child.parentID == parent.id })
                        }
                        .reading(from: tree)
                        .order { $0.name.asc() })

                // The anchor plus everything beneath it, and nothing else.
                #expect(rows.map(\.name) == ["leaf", "middle", "root"])
            }
        }
    }
}
