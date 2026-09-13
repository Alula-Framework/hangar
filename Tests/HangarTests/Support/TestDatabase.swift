import Foundation
import HangarIntrospection
import Logging
import Hangar
import PostgresNIO
import Testing

/// The enclosing suite every DB-touching suite nests in (via extension).
///
/// `.serialized` on the parent applies recursively, so suites that share
/// the fixture tables never truncate them under each other — same pattern
/// as flight-data-postgres's `PostgresIntegrationSuite`.
///
/// `.enabled(if:)` is here for the same reason: a suite trait applies to
/// everything nested inside it, so nesting is all a new integration suite
/// has to remember. Carrying the gate per-suite is what nine files did and
/// seven forgot, and a forgotten gate does not skip — it fails the whole
/// run with `.notConfigured` when a CI secret is missing, which reads as a
/// broken build rather than an unconfigured one.
@Suite(.serialized, .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct PostgresIntegrationSuite {}

/// Integration tests run against a real Postgres — the whole value of a
/// query layer is that its SQL is real; mocking the connection would test
/// nothing that matters. Gated on `HANGAR_TEST_DATABASE_URL`:
///
/// ```
/// $ docker run -d --name hangar-pg -e POSTGRES_PASSWORD=hangar \
///     -e POSTGRES_DB=hangar_test -p 127.0.0.1:55433:5432 postgres:16-alpine
/// $ export HANGAR_TEST_DATABASE_URL="postgres://postgres:hangar@127.0.0.1:55433/hangar_test?sslmode=disable"
/// $ swift test
/// ```
///
/// Without the variable, the integration suite is skipped and only the
/// no-server unit tests run.
enum TestDatabase {
    /// Empty counts as unset. A CI step whose secret did not resolve exports
    /// the variable with an empty value, and treating that as a URL builds a
    /// configuration pointing at localhost — which hangs the run instead of
    /// skipping it, turning a missing secret into a timeout nobody can read.
    static let url: String? = {
        let raw = ProcessInfo.processInfo.environment["HANGAR_TEST_DATABASE_URL"]
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }()

    static var isConfigured: Bool { url != nil }

    static func clientConfiguration() throws -> PostgresClient.Configuration {
        guard let url, let components = URLComponents(string: url), components.host != nil else {
            throw TestDatabaseError.notConfigured
        }
        return PostgresClient.Configuration(
            host: components.host ?? "127.0.0.1",
            port: components.port ?? 5432,
            username: components.user ?? "postgres",
            password: components.password,
            database: components.path.isEmpty ? nil : String(components.path.dropFirst()),
            tls: .disable)
    }
}

enum TestDatabaseError: Error {
    case notConfigured
}


/// Serializes every test that touches the database.
///
/// `withRepo` truncates the fixture tables, so two suites running at the same
/// time delete each other's rows — and swift-testing runs suites in parallel.
/// `.serialized` on a suite only orders the tests *within* it, so the barrier
/// has to be here, around the shared resource itself.
///
/// This was latent rather than new: it stayed hidden while the integration
/// suites were few and while CI ran without HANGAR_TEST_DATABASE_URL, where
/// every one of them skips.
actor DatabaseLock {
    static let shared = DatabaseLock()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Runs `body` with exclusive use of the fixture tables.
    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// Empties the fixture tables with `DELETE` rather than `TRUNCATE`.
///
/// `TRUNCATE` takes an `AccessExclusiveLock`, and taking it on twelve tables in
/// one statement deadlocks against a concurrent sandboxed test that holds row
/// locks on those tables in a different order. Postgres reported it exactly:
///
/// ```
/// deadlock detected
///   8970 (INSERT INTO hangar_posts) waits for RowExclusiveLock on 41477, blocked by 8971
///   8971 (TRUNCATE ...)             waits for AccessExclusiveLock on 41493, blocked by 8970
/// ```
///
/// `DELETE` takes only `RowExclusiveLock`, which does not conflict at the table
/// level — so a truncating suite and a sandboxed one can no longer form a lock
/// cycle. It is also invisible to the sandbox either way: a sandbox's rows are
/// uncommitted, so this never sees them, and this deletes committed rows the
/// sandbox never created.
///
/// One statement per table because `DELETE` has no multi-table form and
/// PostgresNIO uses the extended protocol (no multi-statement strings).
/// `hangar_authors` goes last: `hangar_kv.owner_id` references it, and that is
/// the schema's only foreign key.
///
/// Neither this nor the old `TRUNCATE` resets identity sequences, so tests
/// could never depend on exact generated ids — that has not changed.
func clearFixtureTables(_ client: PostgresClient) async throws {
    let tables = [
        "hangar_kv", "hangar_posts", "hangar_events", "hangar_comments",
        "hangar_profiles", "hangar_tagged", "hangar_tags", "hangar_post_tags",
        "hangar_tagged_posts", "hangar_files", "hangar_nodes",
        "hangar_authors",
    ]
    for table in tables {
        _ = try await client.query(
            PostgresQuery(unsafeSQL: #"DELETE FROM "\#(table)""#), logger: nil)
    }
}

/// Runs `body` with a started client and a `Repo` on it, ensuring the
/// fixture schema exists and the tables are empty.
func withRepo<T: Sendable>(_ body: @Sendable (Repo) async throws -> T) async throws -> T {
    try await DatabaseLock.shared.exclusive {
        try await withRepoUnlocked(body)
    }
}

private func withRepoUnlocked<T: Sendable>(
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            try await TestSchema.shared.ensure(client)
            try await clearFixtureTables(client)
            let result = try await body(Repo(client: client))
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Like ``withRepo(_:)``, with a logger and diagnostics attached — for the
/// suites that assert on what Hangar reports rather than on what it returns.
func withRepo<T: Sendable>(
    logger: Logger,
    diagnostics: QueryDiagnostics,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    try await DatabaseLock.shared.exclusive {
        try await withRepoUnlocked(logger: logger, diagnostics: diagnostics, body)
    }
}

private func withRepoUnlocked<T: Sendable>(
    logger: Logger,
    diagnostics: QueryDiagnostics,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            try await TestSchema.shared.ensure(client)
            try await clearFixtureTables(client)
            var repo = Repo(client: client, logger: logger)
            repo.diagnostics = diagnostics
            let result = try await body(repo)
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// A `SchemaIntrospector` over the fixture database.
///
/// Takes no lock and needs no sandbox: introspection reads `pg_catalog` — table
/// and column *definitions*, never rows — so it neither truncates anything nor
/// cares what any concurrent test has written. It only ever held
/// `DatabaseLock` because every other integration helper did.
func withIntrospector<T: Sendable>(
    _ body: @Sendable (SchemaIntrospector) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            try await TestSchema.shared.ensure(client)
            let result = try await body(SchemaIntrospector(client: client))
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Creates the fixture schema once per process.
///
/// The flag-guarded version of this was unsafe the moment suites stopped being
/// `.serialized`. `ensure` awaits, and **an actor is reentrant across awaits**,
/// so a second caller arriving while the first was still running the DDL saw the
/// flag unset and ran the whole destructive script again: `CREATE TYPE
/// "post_status"` failed with a duplicate-key error on `pg_type`, and the
/// `DROP TABLE`s could fire underneath a test already using the tables. It never
/// showed while one lock funnelled every DB test through a single lane.
///
/// Holding the *task* rather than a flag makes every concurrent caller await the
/// same single execution, which is what "once per process" has to mean when
/// callers can overlap.
actor TestSchema {
    static let shared = TestSchema()
    private var creation: Task<Void, any Error>?

    func ensure(_ client: PostgresClient) async throws {
        if let creation { return try await creation.value }
        let task = Task { try await Self.create(on: client) }
        creation = task
        do {
            try await task.value
        } catch {
            // Don't cache a failure — let the next caller retry rather than
            // every later test inheriting one transient connection error.
            creation = nil
            throw error
        }
    }

    private static func create(on client: PostgresClient) async throws {
        let statements = [
            #"DROP TABLE IF EXISTS "hangar_files""#,
            #"DROP TABLE IF EXISTS "hangar_posts""#,
            #"DROP TABLE IF EXISTS "hangar_events""#,
            #"DROP TABLE IF EXISTS "hangar_authors""#,
            #"DROP TABLE IF EXISTS "hangar_comments""#,
            #"DROP TABLE IF EXISTS "hangar_profiles""#,
            #"DROP TABLE IF EXISTS "hangar_kv""#,
            #"DROP TABLE IF EXISTS "hangar_tagged""#,
            #"DROP TABLE IF EXISTS "hangar_tags""#,
            #"DROP TABLE IF EXISTS "hangar_post_tags""#,
            #"DROP TABLE IF EXISTS "hangar_tagged_posts""#,
            #"DROP TABLE IF EXISTS "hangar_nodes""#,
            #"DROP TYPE IF EXISTS "post_status""#,
            #"CREATE TYPE "post_status" AS ENUM ('draft', 'published', 'archived')"#,
            #"""
            CREATE TABLE "hangar_posts" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "title" text NOT NULL,
                "published" boolean NOT NULL,
                "view_count" bigint NOT NULL,
                "created_at" timestamptz NOT NULL,
                "nickname" text,
                "status" post_status NOT NULL,
                "metadata" jsonb NOT NULL,
                "author_id" uuid NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_events" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "name" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_authors" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_files" (
                "id" uuid PRIMARY KEY,
                "name" text NOT NULL,
                "size_bytes" integer NOT NULL,
                "owner_id" uuid NOT NULL REFERENCES "hangar_authors"("id"),
                "deleted_at" timestamptz
            )
            """#,
            #"""
            CREATE TABLE "hangar_comments" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "post_id" uuid NOT NULL,
                "author_id" uuid NOT NULL,
                "moderator_id" uuid,
                "body" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_profiles" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "author_id" uuid NOT NULL,
                "bio" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_kv" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "key" text NOT NULL UNIQUE,
                "value" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tagged" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "name" text NOT NULL,
                "labels" text[] NOT NULL,
                "scores" bigint[] NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tags" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "label" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_post_tags" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "post_id" uuid NOT NULL,
                "tag_id" uuid NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tagged_posts" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "title" text NOT NULL
            )
            """#,
            // Self-referencing, for recursive CTEs.
            #"""
            CREATE TABLE "hangar_nodes" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" text NOT NULL,
                "parent_id" uuid
            )
            """#,
        ]
        for sql in statements {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
        }
    }
}
