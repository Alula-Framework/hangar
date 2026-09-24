import Foundation
import PropertyBased
import Testing

@testable import Hangar

// `like("%\(term)%")` makes a search box a pattern language: `50%` finds
// `500`, `a_c` finds `abc`, and a lone `%` matches every row. Fluent's
// `contains` has the same hole (it never escapes). `contains`, `hasPrefix`
// and `hasSuffix` escape the term so it matches itself.

@Suite("LIKE escaping")
struct LikeEscapingUnitTests {
    @Test(arguments: [
        ("plain", "plain"),
        ("50%", #"50\%"#),
        ("a_c", #"a\_c"#),
        (#"back\slash"#, #"back\\slash"#),
        (#"%_\"#, #"\%\_\\"#),
        ("", ""),
    ])
    func escapes(input: String, expected: String) {
        #expect(likeEscaped(input) == expected)
    }

    @Test("the pattern is bound, never spliced into the SQL")
    func bound() throws {
        let rendered = try Post.where { $0.title.contains("50%'; --") }.renderedQuery()
        #expect(rendered.sql.contains(#""title" LIKE $1"#))
        #expect(!rendered.sql.contains("50"))
    }
}

extension SandboxedIntegrationSuite {
    @Suite("LIKE escaping against Postgres (sandboxed)")
    struct LikeEscapingIntegrationTests {
        @Test("wildcards in the term match only themselves")
        func literalMatches() async throws {
            try await withSandbox { repo in
                let values = ["50%", "500", "a_c", "abc", #"back\slash"#, "backslash", "Mixed"]
                for (index, value) in values.enumerated() {
                    try await repo.insert(KV(key: "k\(index)", value: value))
                }
                func matching(_ predicate: @escaping @Sendable (KV.Columns) -> Hangar.Predicate) async throws -> Set<String> {
                    Set(try await repo.all(KV.where(predicate)).map(\.value))
                }
                #expect(try await matching { $0.value.contains("50%") } == ["50%"])
                #expect(try await matching { $0.value.contains("a_c") } == ["a_c"])
                #expect(try await matching { $0.value.contains("%") } == ["50%"])
                #expect(try await matching { $0.value.contains(#"\"#) } == [#"back\slash"#])
                #expect(try await matching { $0.value.hasPrefix("50") } == ["50%", "500"])
                #expect(try await matching { $0.value.hasSuffix("%") } == ["50%"])
                #expect(try await matching { $0.value.contains("mixed", caseInsensitive: true) } == ["Mixed"])
                #expect(try await matching { $0.value.contains("mixed") } == [])
            }
        }

        static let alphabet = Gen<Character?>.element(of: Array(#"ab%_\A "#) as [Character]).map { $0! }

        @Test("contains, hasPrefix and hasSuffix agree with Swift's own, on hostile text")
        func differential() async throws {
            try await withSandbox { repo in
                let letters: [Character] = Array(#"ab%_\A "#)
                var values: [String] = []
                for i in 0..<40 {
                    var value = ""
                    for j in 0..<(i % 7) { value.append(letters[(i * 7 + j * 3) % letters.count]) }
                    values.append(value)
                }
                for (index, value) in values.enumerated() {
                    try await repo.insert(KV(key: "d\(index)", value: value))
                }
                await propertyCheck(count: 150, input: Self.alphabet.string(of: 1...3), Gen.bool) { needle, fold in
                    let lower = { (s: String) in fold ? s.lowercased() : s }
                    let cases: [(Hangar.Predicate, (String) -> Bool)] = [
                        (KV.Columns().value.contains(needle, caseInsensitive: fold), { lower($0).contains(lower(needle)) }),
                        (KV.Columns().value.hasPrefix(needle, caseInsensitive: fold), { lower($0).hasPrefix(lower(needle)) }),
                        (KV.Columns().value.hasSuffix(needle, caseInsensitive: fold), { lower($0).hasSuffix(lower(needle)) }),
                    ]
                    for (predicate, swift) in cases {
                        let got = try await repo.all(KV.all.where { _ in predicate }).map(\.key).sorted()
                        let want = values.enumerated().filter { swift($0.element) }.map { "d\($0.offset)" }.sorted()
                        #expect(got == want, "needle \(needle.debugDescription) fold \(fold)")
                    }
                }
            }
        }
    }
}
