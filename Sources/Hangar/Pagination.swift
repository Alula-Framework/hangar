import Foundation

/// One page of results, and enough context to render a pager.
///
/// `total` is the number of rows the query matches *without* the page's limit
/// and offset — one extra `COUNT(*)`, which is what makes `pageCount` and
/// "showing 21–40 of 137" possible. When a caller does not need that, the
/// cursor-based reads below skip the count entirely.
public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    /// Total matching rows, ignoring pagination.
    public let total: Int
    /// 1-based.
    public let page: Int
    public let perPage: Int

    public init(items: [Element], total: Int, page: Int, perPage: Int) {
        self.items = items
        self.total = total
        self.page = page
        self.perPage = max(1, perPage)
    }

    public var pageCount: Int {
        // Integer arithmetic: a Double stops representing every integer at
        // 2^53, and `total` is an Int.
        total <= 0 ? 0 : total / perPage + (total % perPage == 0 ? 0 : 1)
    }
    public var isFirst: Bool { page <= 1 }
    public var isLast: Bool { page >= pageCount }
    public var hasNext: Bool { page < pageCount }
    public var hasPrevious: Bool { page > 1 && total > 0 }
    /// 1-based index of the first item on this page, or nil when empty.
    public var firstIndex: Int? { items.isEmpty ? nil : saturating(offset(page: page, perPage: perPage), plus: 1) }
    public var lastIndex: Int? {
        items.isEmpty ? nil : saturating(offset(page: page, perPage: perPage), plus: items.count)
    }
}

extension Page: Equatable where Element: Equatable {}

extension Page: Encodable where Element: Encodable {
    enum CodingKeys: String, CodingKey {
        case items, total, page, perPage, pageCount, hasNext, hasPrevious
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(total, forKey: .total)
        try c.encode(page, forKey: .page)
        try c.encode(perPage, forKey: .perPage)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(hasNext, forKey: .hasNext)
        try c.encode(hasPrevious, forKey: .hasPrevious)
    }
}

/// What page to fetch, as a value a request can decode straight into.
///
/// Both numbers usually come from a query string, so both are untrusted, and
/// the type keeps them sane however it is made:
///
/// - `page` is at least 1, and `perPage` is between 1 and a maximum (100
///   unless you pass another to ``init(page:perPage:maximumPerPage:)``).
/// - **Decoding clamps too.** A synthesized `Decodable` would assign the
///   fields directly and skip the clamping, so `{"page": -5}` produced a
///   negative `OFFSET` Postgres rejects, and `{"perPage": 100000}` fetched a
///   hundred thousand rows. Missing fields take their defaults, so
///   `?page=2` alone decodes.
/// - The fields are read-only from outside, so the invariant cannot be
///   assigned away after construction.
/// - ``offset`` saturates rather than overflowing. `(page - 1) * perPage`
///   traps on overflow, and a trap in a request handler takes the whole
///   process down: `?page=9223372036854775807` was a one-request crash.
public struct PageRequest: Sendable, Equatable, Codable {
    public private(set) var page: Int
    public private(set) var perPage: Int

    /// The largest `perPage` a request gets without asking for more.
    public static let defaultMaximumPerPage = 100

    /// Clamps on construction: page below 1 becomes 1, and `perPage` is held
    /// between 1 and `maximumPerPage`. A page size arrives from a query string
    /// as often as not, and `?perPage=100000` should be a large page rather
    /// than a way to ask the database for everything.
    public init(page: Int = 1, perPage: Int = 25, maximumPerPage: Int = defaultMaximumPerPage) {
        self.page = max(1, page)
        self.perPage = min(max(1, perPage), max(1, maximumPerPage))
    }

    enum CodingKeys: String, CodingKey { case page, perPage }

    /// Decodes and clamps to ``defaultMaximumPerPage``. Re-clamp with
    /// ``clamped(maximumPerPage:)`` for a different ceiling.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            page: try container.decodeIfPresent(Int.self, forKey: .page) ?? 1,
            perPage: try container.decodeIfPresent(Int.self, forKey: .perPage) ?? 25)
    }

    /// The same request held to a different `perPage` ceiling.
    public func clamped(maximumPerPage: Int) -> PageRequest {
        PageRequest(page: page, perPage: perPage, maximumPerPage: maximumPerPage)
    }

    /// Rows to skip. Saturates at `Int.max` — a page that far out is simply
    /// empty — rather than trapping.
    public var offset: Int { Hangar.offset(page: page, perPage: perPage) }
}

/// `(page - 1) * perPage`, saturating. Pages below 1 count as page 1.
func offset(page: Int, perPage: Int) -> Int {
    let (product, overflow) = (max(1, page) - 1).multipliedReportingOverflow(by: max(1, perPage))
    return overflow ? Int.max : product
}

func saturating(_ value: Int, plus increment: Int) -> Int {
    let (sum, overflow) = value.addingReportingOverflow(increment)
    return overflow ? Int.max : sum
}

extension Repo {
    /// One page, plus the total row count.
    ///
    ///     let page = try await repo.page(
    ///         Post.where { $0.published == true }.order { $0.createdAt.desc() },
    ///         PageRequest(page: 2, perPage: 20))
    ///
    /// Two queries: the page and a `COUNT(*)` over the same predicate. The
    /// count ignores `limit`/`offset`, so `pageCount` is the real number of
    /// pages rather than a guess from the rows in hand.
    ///
    /// **Order your query.** `LIMIT`/`OFFSET` without `ORDER BY` is not
    /// stable in Postgres: the same page can return different rows on two
    /// runs, and a row can appear on two pages or none. A query with no
    /// ordering is paginated by primary key so the result is at least
    /// deterministic, but the order that means something is yours to choose.
    public func page<M: Table>(
        _ query: Query<M, M>, _ request: PageRequest = PageRequest()
    ) async throws -> Page<M> {
        try await paginate(query, request) { try await all($0) }
    }

    /// Projections paginate the same way.
    public func page<M, R>(
        _ query: Query<M, R>, _ request: PageRequest = PageRequest()
    ) async throws -> Page<R> {
        try await paginate(query, request) { try await all($0) }
    }

    private func paginate<M, R, Element: Sendable>(
        _ query: Query<M, R>,
        _ request: PageRequest,
        _ fetch: (Query<M, R>) async throws -> [Element]
    ) async throws -> Page<Element> {
        var paged = query.limit(request.perPage).offset(request.offset)
        if paged.orderings.isEmpty {
            // Deterministic rather than meaningful: LIMIT/OFFSET without an
            // ORDER BY lets Postgres return the same page differently on two
            // runs, so a row can appear twice or not at all.
            paged.orderings = M.schema.primaryKey.map {
                OrderTerm(table: M.schema.name, column: $0.name, direction: .asc)
            }
        }
        // The count must not inherit the page's limit and offset, or it would
        // report the size of the page rather than of the result set.
        var counted = query
        counted.rowLimit = nil
        counted.rowOffset = nil
        // Sequential, deliberately. A Repo bound to a transaction holds one
        // connection, and a single Postgres connection cannot run two queries
        // at once — issuing these concurrently would be wrong exactly where
        // pagination inside a transaction is wanted.
        let items = try await fetch(paged)
        let total = try await count(counted)
        return Page(
            items: items, total: total, page: request.page, perPage: request.perPage)
    }
}
