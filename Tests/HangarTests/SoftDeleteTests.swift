import Foundation
import Testing

@testable import Hangar

// Sandboxed (testing plan, Phase 3). `.serialized` and the DB gate are both
// inherited from `SandboxedIntegrationSuite`, so both are dropped here — and
// `.serialized` is not wanted at all, since a sandbox commits nothing and so has
// nothing to protect.
//
// What needed scoping: every assertion in this suite is a total over
// `StoredFile.all` (1, 2) or `Author.all` (0), which only held because `withRepo`
// truncated the fixture tables on entry. A sandbox truncates nothing and sees
// every *committed* row, so those totals would have counted other suites' files.
// `seed` therefore returns the owner it creates, and each query is scoped to that
// owner's files — `StoredFile.where { $0.ownerID == owner }`, the query the rest
// of the chain (`withDeleted()`, `onlyDeleted()`, `count`, `update`) is built on.
//
// The scoping is deliberately by *owner* rather than by id: the whole point of
// most of these tests is which of the two seeded rows comes back, so both rows
// must stay in range of the query and only the deleted-row scope may exclude one.
// Scoping to a single id would have made the exclusion unobservable.
extension SandboxedIntegrationSuite {
/// Soft deletion.
///
/// The property under test throughout is that a deleted row stops appearing
/// *by default*, on every read path. A soft delete that one code path
/// forgets is worse than none: the row looks gone in a list and reappears in
/// a count, and nothing errors.
@Suite("Soft delete (sandboxed)")
struct SoftDeleteTests {

    /// Returns the owner id along with the rows: every query below is scoped to
    /// this owner's files, since a sandbox also sees files committed elsewhere.
    private func seed(_ repo: Repo) async throws
        -> (owner: UUID, live: StoredFile, doomed: StoredFile)
    {
        let owner = try await repo.insert(Author(id: UUID(), name: "Owner"))
        let live = try await repo.insert(
            StoredFile(
                id: UUID(), name: "keep.txt", sizeBytes: 10, ownerID: owner.id, deletedAt: nil))
        let doomed = try await repo.insert(
            StoredFile(
                id: UUID(), name: "bin.txt", sizeBytes: 20, ownerID: owner.id, deletedAt: nil))
        return (owner.id, live, doomed)
    }

    @Test("an entity with a @Deleted column says so")
    func detectsTheColumn() {
        #expect(StoredFile.isSoftDeletable)
        #expect(StoredFile.schema.deletedAt?.name == "deleted_at")
        // A model without the marker is unaffected.
        #expect(!Post.isSoftDeletable)
        #expect(Post.schema.deletedAt == nil)
    }

    @Test("delete stamps rather than removes")
    func deleteIsSoft() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            let mine = StoredFile.where { $0.ownerID == owner }
            // Gone from the default view...
            #expect(try await repo.all(mine).count == 1)
            // ...but still in the table.
            let raw = try await repo.all(mine.withDeleted())
            #expect(raw.count == 2)
            #expect(raw.first { $0.id == doomed.id }?.deletedAt != nil)
        }
    }

    @Test("every read path excludes deleted rows, not just the obvious one")
    func exclusionIsUniform() async throws {
        try await withSandbox { repo in
            let (owner, live, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The paths that would each need to remember on their own. The
            // one/exists probes are already scoped by the id they look up.
            let mine = StoredFile.where { $0.ownerID == owner }
            #expect(try await repo.all(mine).count == 1)
            #expect(try await repo.count(mine) == 1)
            #expect(try await repo.one(StoredFile.where { $0.id == doomed.id }) == nil)
            #expect(try await repo.exists(StoredFile.where { $0.id == doomed.id }) == false)
            #expect(try await repo.exists(StoredFile.where { $0.id == live.id }) == true)
        }
    }

    @Test("a predicate composes with the exclusion rather than replacing it")
    func predicateComposes() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // Matches the deleted row on name, and must still find nothing.
            // The name is not unique across suites, so the owner is part of the
            // predicate — the name condition is still the one being composed
            // with the exclusion.
            let named = StoredFile.where { $0.name == "bin.txt" && $0.ownerID == owner }
            #expect(try await repo.all(named).isEmpty)
            #expect(try await repo.all(named.withDeleted()).count == 1)
        }
    }

    @Test("withDeleted and onlyDeleted select the other views")
    func scopes() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            let mine = StoredFile.where { $0.ownerID == owner }
            #expect(try await repo.count(mine) == 1)
            #expect(try await repo.count(mine.withDeleted()) == 2)
            #expect(try await repo.count(mine.onlyDeleted()) == 1)
            #expect(try await repo.all(mine.onlyDeleted()).map(\.id) == [doomed.id])
        }
    }

    @Test("restore brings a row back")
    func restore() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            let mine = StoredFile.where { $0.ownerID == owner }
            try await repo.delete(doomed)
            #expect(try await repo.count(mine) == 1)

            try await repo.restore(doomed)
            #expect(try await repo.count(mine) == 2)
            let back = try await repo.one(StoredFile.where { $0.id == doomed.id })
            #expect(back?.deletedAt == nil)
        }
    }

    @Test("deleting twice is reported, not silently re-stamped")
    func deletingTwice() async throws {
        try await withSandbox { repo in
            // Nothing to scope: the assertion is that the second delete throws,
            // which does not depend on what else is in the table.
            let (_, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)
            await #expect(throws: HangarError.self) { try await repo.delete(doomed) }
        }
    }

    @Test("restoring something that was never deleted is reported")
    func restoringALiveRow() async throws {
        try await withSandbox { repo in
            // Deliberately unscoped: the only assertion is that restore throws.
            let (_, live, _) = try await seed(repo)
            await #expect(throws: HangarError.self) { try await repo.restore(live) }
        }
    }

    @Test("forceDelete removes the row for real")
    func forceDelete() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.forceDelete(doomed)

            // Not merely hidden — absent even from the unfiltered view. Both
            // seeded rows are in range of this query; only one survives.
            #expect(
                try await repo.count(StoredFile.where { $0.ownerID == owner }.withDeleted()) == 1)
        }
    }

    @Test("soft-deleting a model without the column is refused")
    func notSoftDeletable() async throws {
        try await withSandbox { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "Ada"))
            await #expect(throws: HangarError.self) { try await repo.softDelete(author) }
            // delete still works — it hard-deletes, which is what the model
            // means. Scoped to this author's id: a soft delete (or a no-op)
            // would leave the row there and make this 1.
            try await repo.delete(author)
            #expect(try await repo.count(Author.where { $0.id == author.id }) == 0)
        }
    }

    @Test("preloading does not resurrect deleted children")
    func preloadExcludesDeleted() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The association is loaded by a separate query from the parent's,
            // so this is the path most likely to forget the exclusion — and
            // the one where forgetting is least visible, since the parent list
            // looks right and only the nested array is wrong.
            // The parent list is scoped to the seeded owner; the *child* query
            // is left to the preload, which is the thing under test.
            let owners = try await repo.all(Author.where { $0.id == owner }.preload(\.files))
            let files = try #require(owners.first).files.get()
            #expect(files.count == 1)
            #expect(files.first?.name == "keep.txt")
        }
    }

    @Test("a preload can opt in to deleted children")
    func preloadCanIncludeDeleted() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The nested tune is an ordinary query builder, so the same
            // opt-in works there. Only the parent query is scoped.
            let owners = try await repo.all(
                Author.where { $0.id == owner }.preload(\.files) { $0.withDeleted() })
            #expect(try #require(owners.first).files.get().count == 2)
        }
    }

    @Test("a set-based update skips deleted rows by default")
    func setBasedUpdateSkipsDeleted() async throws {
        try await withSandbox { repo in
            let (owner, _, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // Scoped to this owner: unscoped, the affected-row count would
            // include every committed file, and the write would touch rows the
            // test never created.
            let mine = StoredFile.where { $0.ownerID == owner }
            let touched = try await repo.update(mine) { $0.sizeBytes.set(to: 999) }
            #expect(touched == 1, "the deleted row must not be updated")

            let all = try await repo.all(mine.withDeleted())
            #expect(all.first { $0.id == doomed.id }?.sizeBytes == 20)
        }
    }
}
}
