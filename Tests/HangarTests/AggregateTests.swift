import Foundation
import PropertyBased
import Testing

@testable import Hangar

// `sum`/`avg` existed only for non-optional integer and floating-point
// columns: a `numeric` column could not be summed at all, nor could a nullable
// one. Fluent decodes SUM/AVG into the field's own type and fails or returns
// nil (fluent-postgres-driver #166, fluent-kit #379, #570); these check the
// answers against Swift's own arithmetic.

@Entity("hangar_measures")
struct Measure: Sendable {
    @ID let id: UUID
    var qty: Int
    var amount: Decimal
    var score: Int32?
    var weight: Double?
    var price: Decimal?
}

extension PostgresIntegrationSuite {
    @Suite("Aggregates against Postgres")
    struct AggregateTests {
        static func withMeasures(_ body: @escaping @Sendable (Repo) async throws -> Void) async throws {
            try await withRepo { repo in
                try await repo.execute("DROP TABLE IF EXISTS hangar_measures")
                try await repo.execute(
                    """
                    CREATE TABLE hangar_measures (id uuid PRIMARY KEY, qty bigint NOT NULL,
                        amount numeric NOT NULL, score integer, weight double precision, price numeric)
                    """)
                var failure: (any Error)?
                do { try await body(repo) } catch { failure = error }
                try await repo.execute("DROP TABLE hangar_measures")
                if let failure { throw failure }
            }
        }

        static func close(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a - b) <= 1e-9 * Swift.max(1, abs(a), abs(b))
        }

        static func close(_ a: Decimal?, _ b: Decimal?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            let difference = abs((a - b as NSDecimalNumber).doubleValue)
            return difference <= 1e-14 * Swift.max(1, abs((a as NSDecimalNumber).doubleValue))
        }

        static let rows = Gen.int(in: -1_000_000_000...1_000_000_000).array(of: 5).array(of: 0...12)

        @Test("sum, avg and count agree with Swift, NULLs and numeric included")
        func differential() async throws {
            try await Self.withMeasures { repo in
                await propertyCheck(count: 100, input: Self.rows) { seeds in
                    try await repo.execute("DELETE FROM hangar_measures")
                    let measures = seeds.map { s in
                        Measure(
                            id: UUID(), qty: s[0], amount: Decimal(s[1]) / 1_000,
                            score: s[2] % 3 == 0 ? nil : Int32(truncatingIfNeeded: s[2]),
                            weight: s[3] % 4 == 0 ? nil : Double(s[3]) / 7,
                            price: s[4] % 2 == 0 ? nil : Decimal(s[4]) / 100)
                    }
                    _ = try await repo.insert(measures)
                    let got = try await repo.one(
                        Measure.all.select {
                            ($0.qty.sum(), $0.qty.avg(), $0.amount.sum(), $0.amount.avg(), $0.score.sum(),
                                $0.score.avg(), $0.score.count(), $0.weight.sum(), $0.price.sum(), $0.price.avg())
                        })
                    let got1 = try #require(got)
                    let n = measures.count
                    let scores = measures.compactMap(\.score).map(Int.init)
                    let weights = measures.compactMap(\.weight)
                    let prices = measures.compactMap(\.price)
                    #expect(got1.0 == (n == 0 ? nil : measures.map(\.qty).reduce(0, +)))
                    #expect(Self.close(got1.1, n == 0 ? nil : Double(measures.map(\.qty).reduce(0, +)) / Double(n)))
                    #expect(got1.2 == (n == 0 ? nil : measures.map(\.amount).reduce(0, +)), "numeric sum is exact")
                    #expect(Self.close(got1.3, n == 0 ? nil : measures.map(\.amount).reduce(0, +) / Decimal(n)))
                    #expect(got1.4 == (scores.isEmpty ? nil : scores.reduce(0, +)))
                    #expect(Self.close(got1.5, scores.isEmpty ? nil : Double(scores.reduce(0, +)) / Double(scores.count)))
                    #expect(got1.6 == scores.count, "count skips NULLs")
                    #expect(Self.close(got1.7, weights.isEmpty ? nil : weights.reduce(0, +)))
                    #expect(got1.8 == (prices.isEmpty ? nil : prices.reduce(0, +)))
                    #expect(Self.close(got1.9, prices.isEmpty ? nil : prices.reduce(0, +) / Decimal(prices.count)))
                }
            }
        }

        @Test("an integer sum past bigint is a typed error, not a wrong total")
        func overflow() async throws {
            try await Self.withMeasures { repo in
                for _ in 0..<2 {
                    try await repo.insert(Measure(id: UUID(), qty: .max, amount: 0, score: nil, weight: nil, price: nil))
                }
                await #expect {
                    _ = try await repo.one(Measure.all.select { $0.qty.sum() })
                } throws: { ($0 as? DatabaseError)?.kind == .numericValueOutOfRange }
            }
        }
    }
}
