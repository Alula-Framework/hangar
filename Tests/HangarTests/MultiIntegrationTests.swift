import Foundation
import Testing

import Hangar

// `Multi`: typed keys, dependent steps, one transaction.

private enum K {
    static let post = MultiKey<Post>("post")
    static let event = MultiKey<Event>("event")
    static let summary = MultiKey<String>("summary")
    static let count = MultiKey<Int>("count")
    static let ghost = MultiKey<Post>("ghost")
}

// Sandboxed (testing plan, Phase 3). Every assertion here was a whole-table
// `count(Post.all)` / `count(Event.all)` against an exact number — 1 when the
// Multi succeeded, 0 when it rolled back — which only ever held because
// `withRepo` truncated the fixture tables on entry. A sandbox truncates nothing
// and sees everything committed, so each test now writes a title unique to that
// run (`uniqueTitle`) and counts rows carrying *that* title. The claims are
// unchanged and each still fails for the right reason: a 1 becomes 0 if the step
// did not run, and a 0 becomes 1 if a rollback did not happen.
//
// A `Multi` is a transaction, so inside a sandbox its steps render as a
// SAVEPOINT rather than a BEGIN/COMMIT. That is exactly the property
// `SandboxTests` G1.3 pins, and it is what these tests need: a failing step
// still unwinds only its own level, and a successful one still leaves its writes
// readable through the same repo. No test here has *commit durability* as its
// subject — nothing asserts from a second connection — so none had to stay on
// `withRepo`.
extension SandboxedIntegrationSuite {
@Suite("Multi (real Postgres, sandboxed)")
struct MultiIntegrationTests {

    /// A title no other suite — and no other run of this one — can collide with,
    /// so a count over it means "the rows this test wrote".
    private static func uniqueTitle(_ label: String) -> String {
        "multi-\(label)-\(UUID().uuidString)"
    }

    @Test("dependent steps see earlier results; success returns typed values")
    func dependentSteps() async throws {
        let title = Self.uniqueTitle("dependent")
        try await withSandbox { repo in
            let multi = Multi()
                .insert(K.post, postChangeset(title: title))
                .insert(K.event) { values in
                    Changeset(Event.self).change(\.name, "event for \(try values[K.post].title)")
                }
                .run(K.summary) { values in
                    "\(try values[K.post].title) / \(try values[K.event].name)"
                }

            switch try await repo.run(multi) {
            case .success(let values):
                #expect(try values[K.post].title == title)
                #expect(try values[K.event].name == "event for \(title)")
                #expect(try values[K.summary] == "\(title) / event for \(title)")
            case .failure(let failure):
                Issue.record("unexpected failure at step '\(failure.key)': \(failure.error)")
            }
            // Both inserts landed. Scoped by the unique title (and, for the
            // event, by the name derived from it) — `Event` has no owner column
            // to hang a scope off, and its generated id is not reproducible
            // under rollback, so the derived name is the only stable handle.
            let posts = try await repo.count(Post.where { $0.title == title })
            let events = try await repo.count(Event.where { $0.name == "event for \(title)" })
            #expect(posts == 1)
            #expect(events == 1)
        }
    }

    @Test("a failing step rolls back every completed step")
    func failureRollsBack() async throws {
        let doomed = Self.uniqueTitle("doomed")
        try await withSandbox { repo in
            let never = Post.sample(title: "never inserted")
            let multi = Multi()
                .insert(K.post, postChangeset(title: doomed))
                .update(K.ghost) { _ in
                    // The row does not exist → HangarError.staleModel.
                    Changeset(original: never).change(\.title, "x")
                }

            switch try await repo.run(multi) {
            case .success:
                Issue.record("the ghost update should have failed")
            case .failure(let failure):
                #expect(failure.key == "ghost")
                #expect(failure.error is HangarError)
                // The doomed insert had completed before the failure —
                // and was rolled back with it.
                #expect(try failure.completed[K.post].title == doomed)
            }
            // The insert really is gone: this counts the exact row the first
            // step wrote, so it is 1 unless the failure unwound it.
            let count = try await repo.count(Post.where { $0.title == doomed })
            #expect(count == 0)
        }
    }

    @Test("run steps get the ambient transaction repo and read its writes")
    func runStepAmbient() async throws {
        let title = Self.uniqueTitle("ambient")
        try await withSandbox { repo in
            let multi = Multi()
                .insert(K.post, postChangeset(title: title))
                .run(K.count) { _ in
                    // Repo.current is the transaction repo, so this
                    // read sees the uncommitted insert above. Scoped to the
                    // step's own row: a repo that could not see the pending
                    // insert would report 0.
                    try await Repo.require().count(Post.where { $0.title == title })
                }
            switch try await repo.run(multi) {
            case .success(let values):
                #expect(try values[K.count] == 1)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }

    @Test("keyless run steps and deletes participate")
    func deleteAndSideEffect() async throws {
        let title = Self.uniqueTitle("to-delete")
        try await withSandbox { repo in
            let existing = try await repo.insert(Post.sample(title: title))
            let multi = Multi()
                .delete(K.ghost) { _ in existing }
                .run { values in
                    let ghost = try values[K.ghost]
                    #expect(ghost.title == title)
                }
            switch try await repo.run(multi) {
            case .success:
                // The delete step really removed the row it was handed.
                let count = try await repo.count(Post.where { $0.id == existing.id })
                #expect(count == 0)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }

    @Test("duplicate step names are rejected before anything runs — merged Multis included")
    func duplicateKeys() async throws {
        let first = Self.uniqueTitle("dup-a")
        let second = Self.uniqueTitle("dup-b")
        try await withSandbox { repo in
            // Built via merging; the two
            // halves collide on K.post and the run must refuse up front.
            let a = Multi().insert(K.post, postChangeset(title: first))
            let b = Multi().insert(K.post, postChangeset(title: second))
            await #expect(throws: HangarError.self) {
                _ = try await repo.run(a.merging(b))
            }
            // "before anything runs": neither insert's row exists. Counting the
            // two titles the halves would have written is the sharp form of the
            // old whole-table zero.
            let count = try await repo.count(Post.where { $0.title.in([first, second]) })
            #expect(count == 0)
        }
    }

    @Test("merged Multis run as one transaction in order")
    func merging() async throws {
        let title = Self.uniqueTitle("merged")
        try await withSandbox { repo in
            let writes = Multi().insert(K.post, postChangeset(title: title))
            let checks = Multi().run(K.count) { _ in
                // Scoped to the merged write: reads 1 only if the two halves
                // really ran in order inside one transaction.
                try await Repo.require().count(Post.where { $0.title == title })
            }
            switch try await repo.run(writes.merging(checks)) {
            case .success(let values):
                #expect(try values[K.count] == 1)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }
}
}
