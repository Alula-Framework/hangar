import Foundation
import PropertyBased
import Testing

@testable import Hangar

// The fixture schema covered uuid, text, boolean, bigint, integer, timestamptz,
// one enum, jsonb and two arrays — nothing tested numeric, bytea, the float
// specials, integer bounds, date, time, timestamp, interval or json. Those are
// where Vapor's stack has shipped real decoding bugs (NUMERIC digits moved,
// dates a day off, timestamps shifted by the session's zone), so each gets a
// round-trip property here, against the server.

// MARK: - Calendar arithmetic

@Suite("Calendar and clock types")
struct TemporalUnitTests {
    @Test("day counts and calendar dates convert both ways across Postgres's whole range")
    func dayCounts() async {
        // 4713 BC to 5874897 AD, Postgres's `date` range.
        await propertyCheck(count: 3_000, input: Gen.int(in: -2_451_545 - 10_957...2_147_483_494 - 10_957)) { days in
            let date = CalendarDate(daysSince1970: days)
            #expect(date.daysSince1970 == days)
            #expect(CalendarDate(year: date.year, month: date.month, day: date.day) == date)
        }
    }

    @Test("agrees with Foundation's Gregorian calendar wherever that calendar is Gregorian")
    func matchesFoundation() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // From 1583, after Foundation's Julian cutover.
        await propertyCheck(count: 2_000, input: Gen.int(in: -140_000...2_900_000)) { days in
            let instant = Date(timeIntervalSince1970: Double(days) * 86_400 + 43_200)
            let parts = calendar.dateComponents([.year, .month, .day], from: instant)
            let date = CalendarDate(instant)
            let ours: [Int] = [date.year, date.month, date.day]
            let theirs: [Int] = [parts.year!, parts.month!, parts.day!]
            #expect(ours == theirs)
            #expect(date.startOfDay() == Date(timeIntervalSince1970: Double(days) * 86_400))
        }
    }

    @Test("a reading after a daylight-saving change the same day lands on the right instant")
    func sameDayTransition() {
        let newYork = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: clocks spring forward at 02:00. 05:00 is EDT (UTC-4).
        let reading = LocalDateTime(date: CalendarDate(year: 2026, month: 3, day: 8)!, time: LocalTime(hour: 5, minute: 0, second: 0)!)
        #expect(reading.instant(in: newYork) == Date(timeIntervalSince1970: 1_772_960_400))  // 09:00Z
    }

    @Test("text and Codable forms round-trip, BC included")
    func textForms() throws {
        for date in [CalendarDate(year: 2026, month: 2, day: 28)!, CalendarDate(year: 0, month: 3, day: 15)!,
            CalendarDate(year: -43, month: 3, day: 15)!, CalendarDate(year: 12, month: 1, day: 1)!]
        {
            #expect(CalendarDate(date.description) == date)
            let json = try JSONEncoder().encode(date)
            #expect(try JSONDecoder().decode(CalendarDate.self, from: json) == date)
        }
        #expect(CalendarDate(year: 0, month: 3, day: 15)!.description == "0001-03-15 BC")
        #expect(CalendarDate(year: 2025, month: 2, day: 29) == nil)
        #expect(CalendarDate(year: 2000, month: 2, day: 29) != nil)
        #expect(CalendarDate(year: 1900, month: 2, day: 29) == nil)
    }

    @Test("a wall-clock reading converts to and from an instant in any zone")
    func wallClock() async {
        let zones = ["UTC", "America/New_York", "Asia/Kathmandu", "Pacific/Kiritimati", "Australia/Lord_Howe"]
            .map { TimeZone(identifier: $0)! }
        await propertyCheck(count: 1_000, input: Gen.int(in: -2_000_000_000...4_000_000_000), Gen.int(in: 0...4)) {
            seconds, zone in
            let instant = Date(timeIntervalSince1970: Double(seconds))
            let reading = LocalDateTime(instant, in: zones[zone])
            let back = reading.instant(in: zones[zone])
            // Always: the instant found shows the same wall clock.
            #expect(LocalDateTime(back, in: zones[zone]) == reading, "\(reading) in \(zones[zone].identifier)")
            // And it is *the* instant unless the reading is ambiguous — inside
            // an hour the clocks repeat, where it names two.
            let offsets = [-7_200.0, 7_200].map { zones[zone].secondsFromGMT(for: instant.addingTimeInterval($0)) }
            if offsets[0] == offsets[1] {
                #expect(back == instant, "\(reading) in \(zones[zone].identifier)")
            }
        }
    }
}

// MARK: - Round trips against the server

@Entity("hangar_types")
struct TypeRow: Sendable {
    @ID let id: UUID
    var amount: Decimal
    var blob: Data
    var double: Double
    var float: Float
    var small: Int16
    var medium: Int32
    var large: Int64
    var text: String
    var instant: Date
    var day: CalendarDate
    var clock: LocalTime
    var wallClock: LocalDateTime
    var span: PostgresInterval
    @JSONB var document: PostMetadata
    var days: [CalendarDate]
}

extension PostgresIntegrationSuite {
    @Suite("Type round-trips against Postgres")
    struct TypeRoundTripTests {
        static func withTypes(_ body: @escaping @Sendable (Repo) async throws -> Void) async throws {
            try await withRepo { repo in
                try await repo.execute("DROP TABLE IF EXISTS hangar_types")
                try await repo.execute(
                    """
                    CREATE TABLE hangar_types (
                        id uuid PRIMARY KEY, amount numeric NOT NULL, blob bytea NOT NULL,
                        double double precision NOT NULL, float real NOT NULL, small smallint NOT NULL,
                        medium integer NOT NULL, large bigint NOT NULL, text text NOT NULL,
                        instant timestamptz NOT NULL, day date NOT NULL, clock time NOT NULL,
                        wall_clock timestamp NOT NULL, span interval NOT NULL, document json NOT NULL,
                        days date[] NOT NULL
                    )
                    """)
                var failure: (any Error)?
                do { try await body(repo) } catch { failure = error }
                try await repo.execute("DROP TABLE hangar_types")
                if let failure { throw failure }
            }
        }

        static let decimals = Gen.oneOf(
            Gen.always("0"), Gen.always("10.08"), Gen.always("10234.543201"), Gen.always("-0.0001"),
            Gen.always("0.00000000000000000001"), Gen.always("12345678901234567890123456789012345678"),
            Gen.number.string(of: 1...20).map { $0 }, Gen.number.string(of: 1...10).map { "-0.\($0)" })
        static let doubles = Gen.oneOf(
            Gen.always(Double.nan), Gen.always(.infinity), Gen.always(-.infinity), Gen.always(-0.0),
            Gen.always(.greatestFiniteMagnitude), Gen.always(.leastNonzeroMagnitude),
            Gen.double(in: -1e300...1e300))
        static let text = Gen.oneOf(
            Gen.unicodeScalar(in: "\u{1}"..."\u{D7FF}").array(of: 0...20).map { String(String.UnicodeScalarView($0)) },
            Gen.unicodeScalar(in: "\u{E000}"..."\u{10FFFF}").array(of: 0...20).map { String(String.UnicodeScalarView($0)) })
        static let micros = Gen.int(in: -200_000_000_000_000_000...200_000_000_000_000_000)
        static let days = Gen.int(in: -2_451_545 - 10_957...2_000_000)

        static func row(_ seed: [Int], _ decimal: String, _ double: Double, _ text: String) -> TypeRow {
            TypeRow(
                id: UUID(), amount: Decimal(string: decimal) ?? 0,
                blob: Data((0..<abs(seed[0] % 300)).map { UInt8(truncatingIfNeeded: $0 &* seed[1]) }),
                double: double, float: Float(double), small: Int16(truncatingIfNeeded: seed[2]),
                medium: Int32(truncatingIfNeeded: seed[3]), large: Int64(seed[4]), text: text,
                instant: Date(timeIntervalSince1970: Double(seed[5] % 10_000_000_000_000) / 1_000_000),
                day: CalendarDate(daysSince1970: seed[6] % 2_000_000),
                clock: LocalTime(unchecked: Int64(abs(seed[7] % 86_400_000_000))),
                wallClock: LocalDateTime(
                    date: CalendarDate(daysSince1970: seed[8] % 1_000_000),
                    time: LocalTime(unchecked: Int64(abs(seed[9] % 86_400_000_000)))),
                span: PostgresInterval(
                    months: Int32(truncatingIfNeeded: seed[10] % 1_000), days: Int32(truncatingIfNeeded: seed[11] % 100_000),
                    microseconds: Int64(seed[12] % 1_000_000_000_000)),
                document: PostMetadata(tags: [text, "ü\"\\"], readingMinutes: seed[13]),
                days: [CalendarDate(daysSince1970: seed[14] % 100_000), CalendarDate(daysSince1970: -seed[14] % 100_000)])
        }

        static func sameBits(_ a: Double, _ b: Double) -> Bool { a.isNaN ? b.isNaN : a.bitPattern == b.bitPattern }
        static func sameBits(_ a: Float, _ b: Float) -> Bool { a.isNaN ? b.isNaN : a.bitPattern == b.bitPattern }

        static func expectSame(_ a: TypeRow, _ b: TypeRow, exactInstant: Bool) {
            #expect(a.amount == b.amount, "\(a.amount) vs \(b.amount)")
            #expect(a.blob == b.blob)
            #expect(sameBits(a.double, b.double), "\(a.double) vs \(b.double)")
            #expect(sameBits(a.float, b.float), "\(a.float) vs \(b.float)")
            #expect([Int64(a.small), Int64(a.medium), a.large] == [Int64(b.small), Int64(b.medium), b.large])
            #expect(a.text == b.text)
            if exactInstant {
                #expect(a.instant == b.instant)
            } else {
                // timestamptz holds microseconds; a Swift Date holds more.
                #expect(abs(a.instant.timeIntervalSince(b.instant)) < 1e-6 * 1.5, "\(a.instant) vs \(b.instant)")
            }
            #expect(a.day == b.day && a.clock == b.clock && a.wallClock == b.wallClock && a.span == b.span)
            #expect(a.document == b.document && a.days == b.days)
        }

        @Test("every column type round-trips, whatever the session's time zone")
        func roundTrip() async throws {
            try await Self.withTypes { repo in
                let zones = ["UTC", "America/Adak", "Pacific/Kiritimati", "Asia/Kathmandu"]
                await propertyCheck(
                    count: 120, input: Gen.int(in: .min ... .max).array(of: 15), Self.decimals, Self.doubles, Self.text,
                    Gen.int(in: 0...3)
                ) { seed, decimal, double, text, zone in
                    let row = Self.row(seed, decimal, double, text)
                    try await repo.transaction { tx in
                        try await tx.execute(SQLFragment(stringLiteral: "SET LOCAL TIME ZONE '\(zones[zone])'"))
                        let stored = try await tx.insert(row)
                        let fetched = try #require(try await tx.one(TypeRow.where { $0.id == row.id }))
                        Self.expectSame(row, stored, exactInstant: false)
                        Self.expectSame(stored, fetched, exactInstant: true)
                        // The server's own reading agrees with the Swift one.
                        for try await (day, clock) in try await tx.execute(
                            "SELECT day::text, clock::text FROM hangar_types WHERE id = \(row.id)"
                        ).decode((String, String).self) {
                            #expect(day == row.day.description)
                            #expect(clock == row.clock.description)
                        }
                        try await tx.execute("DELETE FROM hangar_types WHERE id = \(row.id)")
                    }
                }
            }
        }

        @Test("a Date moves a date column's day with the session's zone; a CalendarDate does not")
        func dateVersusCalendarDate() async throws {
            try await withRepo { repo in
                try await repo.transaction { tx in
                    try await tx.execute("SET LOCAL TIME ZONE 'Asia/Tokyo'")
                    let evening = Date(timeIntervalSince1970: 1_767_297_600)  // 2026-01-01 20:00 UTC
                    for try await day in try await tx.execute("SELECT (\(evening))::date::text").decode(String.self) {
                        #expect(day == "2026-01-02", "the documented pitfall")
                    }
                    let newYear = CalendarDate(year: 2026, month: 1, day: 1)!
                    for try await day in try await tx.execute("SELECT (\(newYear))::text").decode(String.self) {
                        #expect(day == "2026-01-01")
                    }
                }
            }
        }

        @Test("infinite dates and timestamps fail to decode instead of inventing a day")
        func infinities() async throws {
            try await withRepo { repo in
                for sql: SQLFragment in ["SELECT 'infinity'::date", "SELECT '-infinity'::date"] {
                    await #expect(throws: (any Error).self) {
                        for try await _ in try await repo.execute(sql).decode(CalendarDate.self) {}
                    }
                }
                await #expect(throws: (any Error).self) {
                    for try await _ in try await repo.execute("SELECT 'infinity'::timestamp").decode(LocalDateTime.self) {}
                }
            }
        }

        @Test("a NUL in text is refused by the server as a typed error")
        func nulByte() async throws {
            try await withRepo { repo in
                await #expect {
                    try await repo.insert(KV(key: "a\u{0}b", value: "v"))
                } throws: { ($0 as? DatabaseError)?.sqlState == "22021" }
            }
        }
    }
}
