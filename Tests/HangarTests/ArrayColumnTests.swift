import Foundation
import PropertyBased
import Testing

@testable import Hangar

// PostgresNIO decodes an array only when it holds no NULLs, and has no array
// coding for Postgres enums, so `{1,NULL}` made a row undecodable and a
// `role[]` column could not be mapped at all; `status.in([...])` on an enum
// column did not even compile. Fluent's tracker has the same three open.

enum HangarRole: String, PostgresEnum, CaseIterable, Hashable {
    case plain
    case withSpace = "with space"
    case comma = "comma,here"
    case quote = #"quote"d"#
    case backslash = #"back\slash"#
    case brace = "{brace}"
    case null = "NULL"
}

@Entity("hangar_arrays")
struct ArrayRow: Sendable, Equatable {
    @ID let id: UUID
    var roles: EnumArray<HangarRole>
    var samples: NullableArray<Int>
}

@Suite("Array literals")
struct ArrayLiteralTests {
    @Test(arguments: [
        ("{}", [] as [String?]),
        ("{a,NULL,\"NULL\"}", ["a", nil, "NULL"]),
        (#"{"a\"b","c\\d","x,y","{z}"}"#, [#"a"b"#, #"c\d"#, "x,y", "{z}"]),
    ])
    func parses(text: String, expected: [String?]) throws {
        #expect(try parseArrayLiteral(text) == expected)
    }

    @Test("writing then reading any strings gives them back")
    func roundTrip() async {
        await propertyCheck(count: 500, input: Gen.ascii.string(of: 0...8).array(of: 0...5)) { strings in
            let parsed = try parseArrayLiteral(arrayLiteral(strings))
            #expect(parsed == strings.map { Optional($0) })
        }
    }

    @Test("enum membership binds each label and an empty list matches nothing")
    func enumIn() throws {
        #expect(try Post.where { $0.status.in([.draft, .published]) }.renderedQuery().sql
            .contains(#"("status" IN ($1, $2))"#))
        #expect(try Post.where { $0.status.in([]) }.renderedQuery().sql.contains("WHERE FALSE"))
    }
}

extension PostgresIntegrationSuite {
    @Suite("Array columns against Postgres")
    struct ArrayColumnIntegrationTests {
        static func withArrays(_ body: @escaping @Sendable (Repo) async throws -> Void) async throws {
            try await withRepo { repo in
                try await repo.execute("DROP TABLE IF EXISTS hangar_arrays")
                try await repo.execute("DROP TYPE IF EXISTS hangar_role")
                let labels = HangarRole.allCases.map { "'" + $0.rawValue.replacingOccurrences(of: "'", with: "''") + "'" }
                try await repo.execute(SQLFragment(stringLiteral: "CREATE TYPE hangar_role AS ENUM (\(labels.joined(separator: ", ")))"))
                try await repo.execute(
                    "CREATE TABLE hangar_arrays (id uuid PRIMARY KEY, roles hangar_role[] NOT NULL, samples bigint[] NOT NULL)")
                var failure: (any Error)?
                do { try await body(repo) } catch { failure = error }
                try await repo.execute("DROP TABLE hangar_arrays")
                try await repo.execute("DROP TYPE hangar_role")
                if let failure { throw failure }
            }
        }

        static let roles = Gen.element(of: HangarRole.allCases).map { $0 ?? .plain }.array(of: 0...6)
        static let samples = Gen.oneOf(
            Gen.int(in: -5...5).map(Optional.some), Gen.always(Int?.none), Gen.int(in: .min ... .max).map(Optional.some)
        ).array(of: 0...6)

        @Test("enum arrays with hostile labels and arrays with NULL elements round-trip")
        func roundTrip() async throws {
            try await Self.withArrays { repo in
                await propertyCheck(count: 150, input: Self.roles, Self.samples) { roles, samples in
                    let row = ArrayRow(id: UUID(), roles: EnumArray(roles), samples: NullableArray(samples))
                    let stored = try await repo.insert(row)
                    let fetched = try await repo.one(ArrayRow.where { $0.id == row.id })
                    #expect(stored == row)
                    #expect(fetched == row)
                }
            }
        }

        @Test("arrays written by SQL itself decode, NULLs included")
        func decodesServerArrays() async throws {
            try await Self.withArrays { repo in
                let id = UUID()
                try await repo.execute(
                    "INSERT INTO hangar_arrays VALUES (\(id), ARRAY['NULL', 'comma,here']::hangar_role[], ARRAY[NULL, 7, NULL]::bigint[])")
                let row = try await repo.one(ArrayRow.where { $0.id == id })
                #expect(row?.roles == [.null, .comma])
                #expect(row?.samples == [nil, 7, nil])
            }
        }
    }
}

extension SandboxedIntegrationSuite {
    @Suite("Enum membership against Postgres (sandboxed)")
    struct EnumMembershipTests {
        @Test("status IN (...) returns exactly the rows whose status is listed, for every subset")
        func everySubset() async throws {
            try await withSandbox { repo in
                let author = Author(id: UUID(), name: "A")
                try await repo.insert(author)
                let statuses: [PostStatus] = [.draft, .published, .archived]
                for (index, status) in statuses.enumerated() {
                    try await repo.insert(
                        Post(
                            id: UUID(), title: "t\(index)", published: true, viewCount: index, createdAt: Date(),
                            nickname: nil, status: status, metadata: PostMetadata(tags: [], readingMinutes: 1),
                            authorID: author.id))
                }
                for mask in 0..<(1 << statuses.count) {
                    let subset = statuses.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                    let got = try await repo.all(Post.where { $0.authorID == author.id && $0.status.in(subset) })
                    #expect(Set(got.map(\.status)) == Set(subset), "\(subset)")
                }
            }
        }
    }
}
