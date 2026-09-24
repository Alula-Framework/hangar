import Foundation
import PropertyBased
import Testing

@testable import Hangar

// A page request is built from a query string — untrusted by definition —
// and two paths let it past the clamping `init` does: the synthesized
// `Decodable`, which assigned fields directly, and `offset`'s multiplication,
// which trapped on overflow. A trap in a request handler is a crash of the
// whole process, so `?page=9223372036854775807` was a one-request outage.
// Fluent shipped the same crash and fixed it (fluent-kit #637).

@Suite("PageRequest refuses what a query string can say")
struct PageRequestSafetyTests {
    @Test("decoding clamps exactly as construction does")
    func decodingClamps() throws {
        let decode = { (json: String) in
            try JSONDecoder().decode(PageRequest.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"page": -5, "perPage": 100000}"#) == PageRequest(page: 1, perPage: 100))
        #expect(try decode(#"{"page": 0, "perPage": 0}"#) == PageRequest(page: 1, perPage: 1))
        #expect(try decode(#"{"page": 2}"#) == PageRequest(page: 2, perPage: 25))
        #expect(try decode("{}") == PageRequest())
        #expect(throws: DecodingError.self) { try decode(#"{"page": "two"}"#) }
    }

    @Test("an enormous page saturates instead of crashing")
    func enormousPage() {
        #expect(PageRequest(page: .max, perPage: 100).offset == .max)
        #expect(PageRequest(page: .max, perPage: 1).offset == .max - 1)
        let page = Page(items: [1], total: 1, page: .max, perPage: 100)
        #expect(page.firstIndex == .max && page.lastIndex == .max)
    }

    @Test("a narrower ceiling can be applied after decoding")
    func reclamp() {
        #expect(PageRequest(page: 3, perPage: 80).clamped(maximumPerPage: 50).perPage == 50)
    }

    static let anyInt = Gen.oneOf(
        Gen.int(in: -1_000...1_000), Gen.int(in: .min ... .max),
        Gen.always(.min), Gen.always(.max), Gen.always(0))

    @Test("any pair of integers yields a sane request — built or decoded — and nothing traps")
    func invariants() async {
        await propertyCheck(count: 2_000, input: Self.anyInt, Self.anyInt) { page, perPage in
            let built = PageRequest(page: page, perPage: perPage)
            let decoded = try JSONDecoder().decode(
                PageRequest.self, from: Data(#"{"page": \#(page), "perPage": \#(perPage)}"#.utf8))
            for request in [built, decoded] {
                #expect(request.page >= 1)
                #expect((1...PageRequest.defaultMaximumPerPage).contains(request.perPage))
                #expect(request.offset >= 0)
                let exact = (Double(request.page) - 1) * Double(request.perPage)
                if exact < Double(Int.max) / 2 {
                    #expect(request.offset == (request.page - 1) * request.perPage)
                }
                let shown = Page(items: [1, 2], total: 2, page: request.page, perPage: request.perPage)
                #expect((shown.firstIndex ?? 0) >= 1 && (shown.lastIndex ?? 0) >= (shown.firstIndex ?? 0))
            }
            #expect(built == decoded)
        }
    }
}

extension SandboxedIntegrationSuite {
    @Suite("Pagination slices exactly (sandboxed)")
    struct PaginationSliceTests {
        @Test("every page is the exact slice of the ordered result, at any request")
        func pagesAreSlices() async throws {
            try await withSandbox { repo in
                let author = Author(id: UUID(), name: "Ada")
                _ = try await repo.insert(author)
                let count = 23
                for index in 0..<count {
                    _ = try await repo.insert(
                        Post(
                            id: UUID(), title: "p\(index)", published: true, viewCount: index,
                            createdAt: Date(timeIntervalSince1970: Double(index)), nickname: nil,
                            status: .published, metadata: PostMetadata(tags: [], readingMinutes: 1),
                            authorID: author.id))
                }
                let query = Post.where { $0.authorID == author.id }.order { $0.viewCount.asc() }
                let all = try await repo.all(query).map(\.viewCount)
                let pages = Gen.oneOf(Gen.int(in: -3...30), Gen.always(.max), Gen.always(.min))
                let sizes = Gen.oneOf(Gen.int(in: -3...30), Gen.always(.max), Gen.always(.min))
                await propertyCheck(count: 120, input: pages, sizes) { page, size in
                    let request = PageRequest(page: page, perPage: size)
                    let result = try await repo.page(query, request)
                    let start = min(request.offset, all.count)
                    let end = min(start + request.perPage, all.count)
                    #expect(result.items.map(\.viewCount) == Array(all[start..<end]), "\(request)")
                    #expect(result.total == count)
                }
            }
        }
    }
}
