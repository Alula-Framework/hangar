import Foundation
import Testing

@testable import Hangar

@Suite("Cycle detection — rendering")
struct CycleRenderingTests {

    private func walk(_ tree: CommonTable<Node>) -> Query<Node, Node> {
        Node.all
            .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
                Node.join(found, on: { child, parent in child.parentID == parent.id })
            }
            .reading(from: tree)
    }

    @Test("no CYCLE clause unless asked for")
    func absentByDefault() {
        #expect(!SQLRenderer.select(walk(CommonTable<Node>("tree"))).sql.contains("CYCLE"))
    }

    @Test("CYCLE renders after the body, keyed on the chosen column")
    func cycleRenders() {
        let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })
        let sql = SQLRenderer.select(walk(tree)).sql
        #expect(
            sql.contains(
                #") CYCLE "id" SET "hangar_is_cycle" USING "hangar_cycle_path""#))
    }

    @Test("reading it back drops the row that closed the cycle")
    func excludesClosers() {
        let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })
        #expect(SQLRenderer.select(walk(tree)).sql.contains(#"WHERE (NOT "hangar_is_cycle")"#))
        // And the opt-out keeps it.
        let everything = Node.all
            .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
                Node.join(found, on: { child, parent in child.parentID == parent.id })
            }
            .reading(from: tree, includingCycleClosers: true)
        // The clause is still declared; only the filter is gone.
        #expect(SQLRenderer.select(everything).sql.contains("CYCLE \"id\""))
        #expect(!SQLRenderer.select(everything).sql.contains(#"WHERE (NOT "hangar_is_cycle")"#))
    }
}

extension PostgresIntegrationSuite {

    /// Cycle detection against a real server.
    ///
    /// The whole claim is termination, and nothing but running it can show
    /// that. The fixture is a genuine cycle — a → c → b → a — which without a
    /// guard makes Postgres walk until the connection dies.
    @Suite("Cycle detection (real Postgres)")
    struct CycleIntegrationTests {

        private func seedCycle(_ repo: Repo) async throws {
            // root -> child, and child's parent points back at root's child:
            // a cycle of three, reachable from "root".
            let a = UUID()
            let b = UUID()
            let c = UUID()
            _ = try await repo.insert(Node(id: a, name: "root", parentID: c))
            _ = try await repo.insert(Node(id: b, name: "b", parentID: a))
            _ = try await repo.insert(Node(id: c, name: "c", parentID: b))
        }

        @Test("a cyclic graph terminates, and the repeated row is not returned twice")
        func terminates() async throws {
            try await withRepo { repo in
                try await seedCycle(repo)
                let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })
                let rows = try await repo.all(
                    Node.all
                        .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
                            Node.join(found, on: { child, parent in child.parentID == parent.id })
                        }
                        .reading(from: tree)
                        .order { $0.name.asc() })

                // Each node once. Without CYCLE this query does not return.
                #expect(rows.map(\.name) == ["b", "c", "root"])
            }
        }

        @Test("the closing row is there when asked for")
        func closersVisible() async throws {
            try await withRepo { repo in
                try await seedCycle(repo)
                let tree = CommonTable<Node>("tree").detectingCycles(on: { $0.id })
                let rows = try await repo.all(
                    Node.all
                        .withRecursive(tree, anchor: Node.where { $0.name == "root" }) { found in
                            Node.join(found, on: { child, parent in child.parentID == parent.id })
                        }
                        .reading(from: tree, includingCycleClosers: true)
                        .order { $0.name.asc() })
                // The extra row is "root" a second time — the one that closed
                // the cycle, which is the evidence a cycle was there.
                #expect(rows.map(\.name) == ["b", "c", "root", "root"])
            }
        }
    }
}
