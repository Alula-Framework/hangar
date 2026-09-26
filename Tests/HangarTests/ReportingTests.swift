import Foundation
import Testing

@testable import Hangar

struct DailyCount: Decodable, Sendable, Equatable {
    let day: Date
    let posts: Int
    let published: Int
}

struct Spread: Decodable, Sendable {
    let median: Double?
    let p90: Double?
    let publishedViews: Int?
    let meanAgeSeconds: Double?
}

struct Ranked: Decodable, Sendable, Equatable {
    let posts: Int
    let place: Int
}

@Suite("Reporting expressions — rendering")
struct ReportingRenderingTests {
    @Test("grouping by a truncated timestamp renders the same text it selects")
    func truncationMatches() {
        let sql = SQLRenderer.select(
            Post.groupBy { $0.createdAt.truncated(to: .day, in: TimeZone(identifier: "UTC")) }
                .select(into: DailyCount.self) {
                    (
                        day: $0.createdAt.truncated(to: .day, in: TimeZone(identifier: "UTC")),
                        posts: $0.id.count(), published: $0.id.count().filter($0.published)
                    )
                }
        ).sql
        // Foundation on Linux names UTC "GMT"; either way it is a literal.
        let zone = TimeZone(identifier: "UTC")!.identifier
        let truncation = #"date_trunc(('day'), "created_at", ('"# + zone + "'))"
        #expect(sql.contains("SELECT \(truncation) AS \"day\""), "\(sql)")
        #expect(sql.contains("GROUP BY \(truncation)"), "\(sql)")
        #expect(sql.contains(#"count("id") FILTER (WHERE "published") AS "published""#), "\(sql)")
    }

    @Test("a filter goes inside the decoding cast, and a second one narrows")
    func filterInsideCast() {
        let expression = Post.queryColumns.viewCount.sum()
            .filter(Post.queryColumns.published)
            .filter(Post.queryColumns.viewCount > 1)
        var writer = BindWriter()
        let sql = SQLRenderer.render(expression.expression, writer: &writer)
        #expect(sql == #"(sum("view_count") FILTER (WHERE ("published" AND ("view_count" > $1))))::bigint"#, "\(sql)")
    }

    @Test("a zone name that is not only zone characters is bound, never written")
    func hostileZone() {
        #expect(Column<Date>("t").truncated(to: .day).expression.isFunction)
        #expect(Column<Date>.literalZone("America/New_York") == "'America/New_York'")
        #expect(Column<Date>.literalZone("x'; DROP TABLE t; --") == nil)
    }
}

extension SQLExpression {
    fileprivate var isFunction: Bool {
        if case .function = self { return true }
        return false
    }
}

extension PostgresIntegrationSuite {
    @Suite("Reporting expressions (real Postgres)")
    struct ReportingIntegrationTests {
        private static func seed(_ repo: Repo, marker: String) async throws {
            let day: TimeInterval = 86_400
            let base = Date(timeIntervalSince1970: 1_700_006_400)  // a UTC midnight
            let rows: [(TimeInterval, Int, Bool, PostStatus)] = [
                (0, 1, true, .published), (3_600, 2, false, .draft), (day, 3, true, .published),
                (day + 60, 4, true, .published), (day + 120, 10, false, .draft),
            ]
            for (offset, views, published, status) in rows {
                var post = Post.sample(title: "\(marker)-\(views)", published: published, viewCount: views, status: status)
                post.createdAt = base.addingTimeInterval(offset)
                try await repo.insert(post)
            }
        }

        @Test("counts per UTC day, with a FILTER, ordered by the aggregate")
        func dailyTrend() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await Self.seed(repo, marker: marker)
                let utc = TimeZone(identifier: "UTC")
                let days = try await repo.all(
                    Post.where { $0.title.hasPrefix(marker) }
                        .groupBy { $0.createdAt.truncated(to: .day, in: utc) }
                        .select(into: DailyCount.self) {
                            (
                                day: $0.createdAt.truncated(to: .day, in: utc), posts: $0.id.count(),
                                published: $0.id.count().filter($0.published)
                            )
                        }
                        .order { $0.id.count().desc() })
                #expect(days.map(\.posts) == [3, 2])
                #expect(days.map(\.published) == [2, 1])
                #expect(days.first?.day == Date(timeIntervalSince1970: 1_700_006_400 + 86_400))
            }
        }

        @Test("median and p90 interpolate; a filtered sum and interval arithmetic answer")
        func spread() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await Self.seed(repo, marker: marker)
                let rows = try await repo.all(
                    Post.where { $0.title.hasPrefix(marker) }.select(into: Spread.self) {
                        (
                            median: $0.viewCount.median(), p90: $0.viewCount.percentile(0.9),
                            publishedViews: $0.viewCount.sum().filter($0.published),
                            meanAgeSeconds: ColumnExpression.transactionTimestamp.interval(since: $0.createdAt).seconds.avg()
                        )
                    })
                let spread = try #require(rows.first)
                #expect(spread.median == 3)
                #expect(abs((spread.p90 ?? 0) - 7.6) < 1e-9)  // 4 + 0.6 × (10 − 4)
                #expect(spread.publishedViews == 8)
                let expectedAge = Date().timeIntervalSince1970 - (1_700_006_400 + (0 + 3_600 + 86_400 * 3 + 180) / 5)
                #expect(abs((spread.meanAgeSeconds ?? 0) - expectedAge) < 120)
            }
        }

        @Test("a window ordered by an aggregate ranks the groups")
        func rankByAggregate() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await Self.seed(repo, marker: marker)
                let ranked = try await repo.all(
                    Post.where { $0.title.hasPrefix(marker) }
                        .groupBy { $0.status }
                        .select(into: Ranked.self) {
                            (posts: $0.id.count(), place: rank().over(.order(by: $0.id.count().desc())))
                        }
                        .order { $0.id.count().desc() })
                #expect(ranked == [
                    Ranked(posts: 3, place: 1), Ranked(posts: 2, place: 2),
                ])
            }
        }

        @Test("arithmetic in GROUP BY groups by the computed value")
        func groupByArithmetic() async throws {
            try await withSandbox { repo in
                let marker = UUID().uuidString
                try await Self.seed(repo, marker: marker)
                let buckets = try await repo.all(
                    Post.where { $0.title.hasPrefix(marker) }
                        .groupBy { $0.viewCount.divided(by: 5) }
                        .select { $0.id.count() })
                #expect(buckets.sorted() == [1, 4])
            }
        }
    }
}
