import Foundation
import NIOCore
import PostgresNIO

/// A day on the calendar — the Swift shape of a Postgres `date` column.
///
/// `Date` is an instant, and a `date` column is not one. Binding a `Date` to
/// a `date` column goes through `timestamptz`, and Postgres converts that to
/// a day **in the session's time zone**: the same `Date` stores as the 1st in
/// a UTC session and the 2nd in Tokyo, and reads back as midnight UTC of
/// whichever it was. A birthday then moves depending on which server wrote
/// it. `CalendarDate` travels as Postgres's own day count, so no time zone is
/// ever consulted:
///
/// ```swift
/// @Entity("people")
/// struct Person {
///     @ID var id: UUID
///     var birthday: CalendarDate          // date
/// }
///
/// Person.where { $0.birthday >= CalendarDate(year: 2000, month: 1, day: 1)! }
/// ```
///
/// Years are astronomical, like Postgres's internals: year 0 is 1 BC. The
/// calendar is the proleptic Gregorian one Postgres uses, so days before
/// 1582 match the server rather than Foundation's Julian cutover. Postgres's
/// `infinity` and `-infinity` have no calendar day and fail to decode.
public struct CalendarDate: Sendable, Hashable, Comparable, ColumnCodable, CustomStringConvertible, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Nil when the day does not exist (February 30th, month 13).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.days(inMonth: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The calendar day `date` falls on in `timeZone`.
    ///
    /// Computed from the zone's offset and the proleptic calendar rather than
    /// Foundation's `Calendar`, which switches to the Julian calendar before
    /// October 1582 and would disagree with Postgres by up to ten days there.
    public init(_ date: Date, in timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        let local = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        self.init(daysSince1970: Int((local / 86_400).rounded(.down)))
    }

    /// Midnight at the start of this day in `timeZone`.
    public func startOfDay(in timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Date {
        let midnightUTC = Date(timeIntervalSince1970: Double(daysSince1970) * 86_400)
        // The offset that applies at local midnight, which differs from the
        // one at UTC midnight when a daylight-saving change falls between.
        let guess = midnightUTC.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: midnightUTC)))
        return midnightUTC.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: guess)))
    }

    init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// `2026-01-31`, or `0044-03-15 BC` — the text Postgres prints.
    public var description: String {
        let displayYear = year > 0 ? year : 1 - year
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(displayYear, 4))-\(pad(month, 2))-\(pad(day, 2))\(year > 0 ? "" : " BC")"
    }

    /// Parses `YYYY-MM-DD` (optionally with Postgres's ` BC` suffix).
    public init?(_ text: String) {
        var text = Substring(text)
        var bc = false
        if text.hasSuffix(" BC") {
            bc = true
            text = text.dropLast(3)
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let y = Int(parts[0]), y > 0, let m = Int(parts[1]), let d = Int(parts[2]),
            parts[1].count == 2, parts[2].count == 2
        else { return nil }
        self.init(year: bc ? 1 - y : y, month: m, day: d)
    }

    // MARK: Codable — the ISO text form

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = CalendarDate(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a YYYY-MM-DD date: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: Day arithmetic

    /// Days since 1970-01-01 (negative before), proleptic Gregorian.
    var daysSince1970: Int {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(daysSince1970 z: Int) {
        // Howard Hinnant's civil_from_days.
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        self.init(unchecked: yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func days(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Postgres counts `date` as days from 2000-01-01.
    static let postgresEpochOffset = 10_957

    // MARK: Wire format

    public static var psqlType: PostgresDataType { .date }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        buffer.writeInteger(Int32(truncatingIfNeeded: daysSince1970 - Self.postgresEpochOffset), as: Int32.self)
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        switch format {
        case .binary:
            guard type == .date, let days = buffer.readInteger(as: Int32.self),
                days != .max, days != .min  // infinity, -infinity
            else { throw PostgresDecodingError.Code.failure }
            self.init(daysSince1970: Int(days) + Self.postgresEpochOffset)
        case .text:
            guard let text = buffer.readString(length: buffer.readableBytes), let value = CalendarDate(text) else {
                throw PostgresDecodingError.Code.failure
            }
            self = value
        }
    }
}

/// `date[]` columns, and `birthday.in([...])` as one bound array.
extension CalendarDate: PostgresArrayEncodable, PostgresArrayDecodable {
    public static var psqlArrayType: PostgresDataType { .dateArray }
}

extension CalendarDate: DynamicFilterConvertible {
    /// A `YYYY-MM-DD` string.
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> CalendarDate? {
        guard case .string(let text) = value else { return nil }
        return CalendarDate(text)
    }
}
