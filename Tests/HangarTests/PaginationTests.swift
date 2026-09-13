import Foundation
import Testing

@testable import Hangar

/// `Page`'s arithmetic, which is where off-by-ones live.
@Suite("Page arithmetic")
struct PageArithmeticTests {

    @Test("page counts round up, so a partial last page still counts")
    func pageCount() {
        #expect(Page(items: [1], total: 0, page: 1, perPage: 10).pageCount == 0)
        #expect(Page(items: [1], total: 1, page: 1, perPage: 10).pageCount == 1)
        #expect(Page(items: [1], total: 10, page: 1, perPage: 10).pageCount == 1)
        #expect(Page(items: [1], total: 11, page: 1, perPage: 10).pageCount == 2)
        #expect(Page(items: [1], total: 137, page: 1, perPage: 20).pageCount == 7)
    }

    @Test("first and last are honest at the edges")
    func edges() {
        let only = Page(items: [1], total: 5, page: 1, perPage: 10)
        #expect(only.isFirst && only.isLast)
        #expect(!only.hasNext && !only.hasPrevious)

        let middle = Page(items: [1], total: 100, page: 3, perPage: 10)
        #expect(!middle.isFirst && !middle.isLast)
        #expect(middle.hasNext && middle.hasPrevious)

        // An empty result set has no previous page to go back to, even on
        // page 3 — a stale link should not offer one.
        let empty = Page(items: [Int](), total: 0, page: 3, perPage: 10)
        #expect(!empty.hasNext && !empty.hasPrevious)
        #expect(empty.firstIndex == nil && empty.lastIndex == nil)
    }

    @Test("the showing-x-to-y range is 1-based and clamps to what arrived")
    func indices() {
        let page = Page(items: Array(1...20), total: 137, page: 2, perPage: 20)
        #expect(page.firstIndex == 21)
        #expect(page.lastIndex == 40)

        // A short final page reports what it holds, not what it could hold.
        let last = Page(items: Array(1...17), total: 137, page: 7, perPage: 20)
        #expect(last.firstIndex == 121)
        #expect(last.lastIndex == 137)
    }

    @Test("a request clamps rather than trusting a query string")
    func requestClamping() {
        #expect(PageRequest(page: 0).page == 1)
        #expect(PageRequest(page: -5).page == 1)
        #expect(PageRequest(perPage: 0).perPage == 1)
        // A page size is user input; it must not become "fetch everything".
        #expect(PageRequest(perPage: 100_000).perPage == 100)
        #expect(PageRequest(perPage: 500, maximumPerPage: 1000).perPage == 500)
        #expect(PageRequest(page: 3, perPage: 20).offset == 40)
    }
}

// Sandboxed (testing plan, Phase 3). Every assertion here is an exact total
// (25, 13, 5, 30, 12) over `Post.all`, which only held because withRepo
// truncated first. `seed` now returns the author it creates and every query is
// scoped to that author's posts, which preserves each total exactly while making
// the tests independent of anything else committed.
extension SandboxedIntegrationSuite {
@Suite("Pagination against Postgres (sandboxed)")
struct PaginationIntegrationTests {

    /// Returns the id of the author owning the seeded posts, for scoping.
    private func seed(_ repo: Repo, count: Int) async throws -> UUID {
        let author = Author(id: UUID(), name: "Ada")
        _ = try await repo.insert(author)
        for index in 0..<count {
            _ = try await repo.insert(
                Post(
                    id: UUID(), title: String(format: "post-%03d", index), published: index % 2 == 0,
                    viewCount: index, createdAt: Date(timeIntervalSince1970: Double(index)),
                    nickname: nil, status: .published, metadata: PostMetadata(tags: [], readingMinutes: index),
                    authorID: author.id))
        }
        return author.id
    }

    @Test("a page carries its slice and the total behind it")
    func pageAndTotal() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 25)

            let page = try await repo.page(
                Post.where { $0.authorID == owner }.order { $0.viewCount.asc() },
                PageRequest(page: 2, perPage: 10))

            #expect(page.items.count == 10)
            #expect(page.total == 25, "the count ignores limit and offset")
            #expect(page.pageCount == 3)
            #expect(page.items.first?.viewCount == 10)
            #expect(page.items.last?.viewCount == 19)
            #expect(page.hasNext && page.hasPrevious)
        }
    }

    @Test("the count respects the predicate, not just the table")
    func countRespectsPredicate() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 25)

            let page = try await repo.page(
                Post.where { $0.authorID == owner && $0.published == true }
                    .order { $0.viewCount.asc() },
                PageRequest(page: 1, perPage: 5))

            // 13 of 25 have an even viewCount.
            #expect(page.total == 13)
            #expect(page.items.count == 5)
            #expect(page.items.allSatisfy { $0.published })
        }
    }

    @Test("the last page is short, and knows it is last")
    func shortLastPage() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 25)

            let page = try await repo.page(
                Post.where { $0.authorID == owner }.order { $0.viewCount.asc() },
                PageRequest(page: 3, perPage: 10))

            #expect(page.items.count == 5)
            #expect(page.isLast && !page.hasNext)
            #expect(page.lastIndex == 25)
        }
    }

    @Test("a page past the end is empty rather than an error")
    func pastTheEnd() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 5)
            let page = try await repo.page(
                Post.where { $0.authorID == owner }, PageRequest(page: 99, perPage: 10))
            #expect(page.items.isEmpty)
            #expect(page.total == 5)
            #expect(!page.hasNext)
        }
    }

    @Test("an unordered query still paginates without repeating rows")
    func unorderedIsStable() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 30)

            // No .order at all — pagination imposes the primary key so pages
            // partition the result set instead of overlapping.
            var seen: Set<UUID> = []
            for number in 1...3 {
                let page = try await repo.page(
                    Post.where { $0.authorID == owner }, PageRequest(page: number, perPage: 10))
                for item in page.items { seen.insert(item.id) }
            }
            #expect(seen.count == 30, "three pages of ten must be thirty distinct rows")
        }
    }

    @Test("projections paginate too")
    func projections() async throws {
        try await withSandbox { repo in
            let owner = try await seed(repo, count: 12)

            let page = try await repo.page(
                Post.where { $0.authorID == owner }
                    .order { $0.viewCount.asc() }
                    .select { ($0.title, $0.viewCount) },
                PageRequest(page: 2, perPage: 5))

            #expect(page.items.count == 5)
            #expect(page.total == 12)
            #expect(page.items.first?.1 == 5)
        }
    }
}
}
