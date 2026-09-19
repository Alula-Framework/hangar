import Testing

/// Makes a database-less run say so.
///
/// Every suite that needs Postgres is gated on `HANGAR_TEST_DATABASE_URL`, and
/// a gated suite that does not run is *silently* absent: `swift test` prints a
/// green summary, and the only hint that two thirds of the suite never executed
/// is a test count nobody has memorised. That reads as "everything passed" when
/// it means "the unit tests passed and the integration tests were not attempted".
///
/// This suite is the inverse gate — it runs **only** when the database is
/// missing — so the run always carries one loud, named line about what was
/// skipped. It deliberately *passes*: working without a database is legitimate
/// (the renderer tests are the fast inner loop, and CI without a service
/// container is a real configuration). What it must not do is let the omission
/// go unmentioned.
@Suite("Database configuration")
struct DatabaseGateTests {

    @Test(
        "NOTE: no database configured — the integration suites did NOT run",
        .enabled(if: !TestDatabase.isConfigured))
    func databaseIsNotConfigured() {
        print(
            """

            ┌──────────────────────────────────────────────────────────────────────┐
            │  HANGAR_TEST_DATABASE_URL is not set.                                │
            │                                                                      │
            │  Every suite that talks to Postgres was SKIPPED. What ran is the     │
            │  renderer/unit half — real coverage, but it cannot tell you whether  │
            │  any SQL is correct, only whether it was built as intended.          │
            │                                                                      │
            │  To run the whole suite:                                             │
            │                                                                      │
            │    docker run -d --name hangar-pg -e POSTGRES_PASSWORD=hangar \\      │
            │      -e POSTGRES_DB=hangar_test -p 127.0.0.1:55433:5432 \\            │
            │      postgres:16-alpine                                              │
            │                                                                      │
            │    export HANGAR_TEST_DATABASE_URL=\\                                 │
            │      "postgres://postgres:hangar@127.0.0.1:55433/hangar_test?sslmode=disable"
            │                                                                      │
            │    swift test                                                        │
            │                                                                      │
            │  And do not read the summary line as a count of what ran:            │
            │  "Test run with N tests" counts the tests swift-testing DISCOVERED,  │
            │  not the ones it executed. A database-less run prints the same N as  │
            │  a full one while executing roughly half of them.                    │
            └──────────────────────────────────────────────────────────────────────┘

            """)
    }

    /// The positive counterpart, so the configured case is equally legible —
    /// a run that says nothing about the database is otherwise ambiguous
    /// between "configured" and "this check is broken".
    @Test(
        "database configured — integration suites will run",
        .enabled(if: TestDatabase.isConfigured))
    func databaseIsConfigured() {
        #expect(TestDatabase.url != nil)
    }
}
