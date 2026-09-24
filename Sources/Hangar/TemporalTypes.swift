import Foundation
import NIOCore
import PostgresNIO

// The Postgres temporal types that are not instants. `Date` is an instant and
// maps to `timestamptz`; used against these columns it goes through an
// implicit cast that consults the session's time zone, so the value written
// depends on which server wrote it. These types carry the column's own wire
// format, and no time zone is ever consulted.

/// A wall-clock date and time with no zone — a `timestamp` (without time
/// zone) column.
///
/// A `Date` bound to a `timestamp` column is converted from `timestamptz` in
/// the session's time zone: noon UTC is stored as `07:00` by a session in New
/// York, and read back as `07:00` UTC — five hours off. Use this type for
/// such columns, or better, make the column `timestamptz` and use `Date`.
public struct LocalDateTime: Sendable, Hashable, Comparable, ColumnCodable, CustomStringConvertible {
    public var date: CalendarDate
    public var time: LocalTime

    public init(date: CalendarDate, time: LocalTime) {
        self.date = date
        self.time = time
    }

    /// The wall-clock reading of `instant` in `timeZone`.
    public init(_ instant: Date, in timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        let local = instant.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: instant))
        let micros = Int64((local * 1_000_000).rounded(.down))
        let (days, remainder) = micros.floorDividedBy(86_400_000_000)
        self.init(date: CalendarDate(daysSince1970: Int(days)), time: LocalTime(unchecked: remainder))
    }

    /// The instant this wall-clock reading denotes in `timeZone`.
    ///
    /// The zone's offset is the one in force *at that time*, not at the
    /// day's midnight, so readings after a daylight-saving change on the
    /// same day land correctly. A reading in the hour repeated when clocks
    /// fall back names two instants; one of them is returned. A reading in
    /// the hour skipped when clocks spring forward names none; it is
    /// interpreted with the offset from before the change.
    public func instant(in timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Date {
        let wall = Double(date.daysSince1970) * 86_400 + Double(time.microsecondsSinceMidnight) / 1_000_000
        var guess = Date(timeIntervalSince1970: wall - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall))))
        guess = Date(timeIntervalSince1970: wall - Double(timeZone.secondsFromGMT(for: guess)))
        return Date(timeIntervalSince1970: wall - Double(timeZone.secondsFromGMT(for: guess)))
    }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.date, lhs.time) < (rhs.date, rhs.time)
    }

    public var description: String { "\(date.description.replacingOccurrences(of: " BC", with: "")) \(time)\(date.year > 0 ? "" : " BC")" }

    var microsecondsSince2000: Int64 {
        Int64(date.daysSince1970 - CalendarDate.postgresEpochOffset) * 86_400_000_000 + time.microsecondsSinceMidnight
    }

    public static var psqlType: PostgresDataType { .timestamp }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        buffer.writeInteger(microsecondsSince2000, as: Int64.self)
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        guard format == .binary, type == .timestamp, let micros = buffer.readInteger(as: Int64.self),
            micros != .max, micros != .min  // infinity, -infinity
        else { throw PostgresDecodingError.Code.failure }
        let (days, remainder) = micros.floorDividedBy(86_400_000_000)
        self.init(
            date: CalendarDate(daysSince1970: Int(days) + CalendarDate.postgresEpochOffset),
            time: LocalTime(unchecked: remainder))
    }
}

/// A time of day with no date or zone — a `time` column. Microsecond
/// precision, like Postgres.
public struct LocalTime: Sendable, Hashable, Comparable, ColumnCodable, CustomStringConvertible {
    /// 0 ..< 86,400,000,000. (Postgres also accepts `24:00:00`, which this
    /// type rejects rather than wrapping into the next day.)
    public let microsecondsSinceMidnight: Int64

    public init?(hour: Int, minute: Int, second: Int, microsecond: Int = 0) {
        guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second),
            (0..<1_000_000).contains(microsecond)
        else { return nil }
        self.microsecondsSinceMidnight =
            ((Int64(hour) * 60 + Int64(minute)) * 60 + Int64(second)) * 1_000_000 + Int64(microsecond)
    }

    init(unchecked micros: Int64) { self.microsecondsSinceMidnight = micros }

    public var hour: Int { Int(microsecondsSinceMidnight / 3_600_000_000) }
    public var minute: Int { Int(microsecondsSinceMidnight / 60_000_000 % 60) }
    public var second: Int { Int(microsecondsSinceMidnight / 1_000_000 % 60) }
    public var microsecond: Int { Int(microsecondsSinceMidnight % 1_000_000) }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        lhs.microsecondsSinceMidnight < rhs.microsecondsSinceMidnight
    }

    /// `13:05:09` or `13:05:09.000250` — as Postgres prints it.
    public var description: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        var text = "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
        if microsecond != 0 {
            var fraction = pad(microsecond, 6)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text
    }

    public static var psqlType: PostgresDataType { .time }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        buffer.writeInteger(microsecondsSinceMidnight, as: Int64.self)
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        guard format == .binary, type == .time, let micros = buffer.readInteger(as: Int64.self),
            (0..<86_400_000_000).contains(micros)
        else { throw PostgresDecodingError.Code.failure }
        self.microsecondsSinceMidnight = micros
    }
}

/// A Postgres `interval`: months, days and microseconds, kept apart.
///
/// Not a `Duration`, because an interval is not a length of time until it is
/// added to a date: `1 month` is 28 to 31 days, and `1 day` is 23 to 25 hours
/// across a daylight-saving change. Postgres keeps the three parts separate
/// for that reason, and so does this type — `interval '1 mon'` and
/// `interval '30 days'` are different values that compare unequal here.
public struct PostgresInterval: Sendable, Hashable, ColumnCodable, CustomStringConvertible {
    public var months: Int32
    public var days: Int32
    public var microseconds: Int64

    public init(months: Int32 = 0, days: Int32 = 0, microseconds: Int64 = 0) {
        self.months = months
        self.days = days
        self.microseconds = microseconds
    }

    /// An interval of exactly `duration` — no months or days.
    public init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self.init(microseconds: seconds * 1_000_000 + attoseconds / 1_000_000_000_000)
    }

    public var description: String { "\(months) months \(days) days \(microseconds) µs" }

    public static var psqlType: PostgresDataType { .interval }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        buffer.writeInteger(microseconds, as: Int64.self)
        buffer.writeInteger(days, as: Int32.self)
        buffer.writeInteger(months, as: Int32.self)
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        guard format == .binary, type == .interval,
            let (micros, days, months) = buffer.readMultipleIntegers(endianness: .big, as: (Int64, Int32, Int32).self)
        else { throw PostgresDecodingError.Code.failure }
        self.init(months: months, days: days, microseconds: micros)
    }
}

extension Int64 {
    /// Floor division and the non-negative remainder that goes with it.
    func floorDividedBy(_ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        let quotient = self / divisor
        let remainder = self % divisor
        return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
    }
}
