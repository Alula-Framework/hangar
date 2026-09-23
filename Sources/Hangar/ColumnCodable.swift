import Foundation
import NIOCore
import PostgresNIO

// MARK: - ColumnCodable

/// Any type usable as an `@Entity` column.
///
/// Named `ColumnCodable`, not the design's `PostgresCodable`, because
/// PostgresNIO already exports `PostgresCodable` and Hangar re-exports
/// PostgresNIO — same collision-avoidance logic that renamed `@Table` to
/// `@Entity`.
///
/// It is a thin refinement of PostgresNIO's encoding protocols: conforming a
/// custom type means implementing PostgresNIO's `encode`/`init(from:)` pair,
/// nothing Hangar-specific.
public protocol ColumnCodable: PostgresEncodable, PostgresDecodable, Sendable {}

// The stock column types: primitives, UUID, Date, Data.
extension Bool: ColumnCodable {}
extension Int: ColumnCodable {}
extension Int16: ColumnCodable {}
extension Int32: ColumnCodable {}
extension Int64: ColumnCodable {}
extension Float: ColumnCodable {}
extension Double: ColumnCodable {}
extension String: ColumnCodable {}
extension UUID: ColumnCodable {}
extension Date: ColumnCodable {}
extension Data: ColumnCodable {}
extension Decimal: ColumnCodable {}

/// Array columns — `integer[]`, `text[]`, `uuid[]` and friends:
///
/// ```swift
/// @Entity("posts")
/// struct Post {
///     @ID var id: UUID
///     @Column var tags: [String]        // text[]
/// }
/// ```
///
/// Rides directly on PostgresNIO's array codings, so the supported element
/// types are exactly the ones PostgresNIO can put in and read out of a
/// Postgres array: `Bool`, `Int`, `Int16`, `Int32`, `Int64`, `Float`,
/// `Double`, `String`, `UUID`, and `Date`.
///
/// `Decimal` and `Data` are `ColumnCodable` as scalars but have no array
/// coding in PostgresNIO, so `[Decimal]` (`numeric[]`) and `[Data]`
/// (`bytea[]`) columns are not supported — that is an upstream limitation,
/// not a Hangar policy.
extension Array: ColumnCodable
where
    Element: ColumnCodable & PostgresArrayEncodable & PostgresArrayDecodable,
    Element == Element._DecodableType
{}

// MARK: - PostgresEnum

/// A Swift `String`-raw enum stored as a Postgres `CREATE TYPE... AS ENUM`
/// column:
///
/// ```swift
/// enum Status: String, PostgresEnum { case draft, published, archived }
/// ```
///
/// Encoding uses the `unknown` parameter type (OID 705) in text format, so
/// the server infers the enum type from the expression's context — the same
/// behavior libpq gives untyped text literals, and the dialect accommodation
/// the alula-data-postgres spike proved out (SPIKE-FINDINGS S1): a
/// parameter *declared* TEXT is rejected for an enum-typed column, while an
/// `unknown` one type-checks against anything with a text input function.
public protocol PostgresEnum: RawRepresentable, ColumnCodable, DynamicFilterConvertible
where RawValue == String {}

extension PostgresEnum {
    /// A `.string` filter value matched against the case labels; anything
    /// else, or a label that names no case, is a type mismatch rather than a
    /// coercion.
    ///
    /// Without this, `AnyColumn(\.status)` did not compile for an
    /// enum-valued column — so `?status=booked`, the most ordinary runtime
    /// filter an API has, could not be put on a `DynamicallyFilterable`
    /// allowlist at all. Every conformer already carries what the lookup
    /// needs, and the allowlist, not the column's type, is the boundary that
    /// keeps a filter safe.
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Self? {
        guard case .string(let raw) = value else { return nil }
        return Self(rawValue: raw)
    }

    /// `unknown` (OID 705): the server infers the enum type from context.
    public static var psqlType: PostgresDataType { .unknownOID }
    /// Enum labels travel as text.
    public static var psqlFormat: PostgresFormat { .text }

    /// Writes the case's raw label.
    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(rawValue)
    }

    /// Reads a label and matches it to a case; an unknown label throws
    /// `HangarError.invalidEnumValue` naming both.
    public init<JSONDecoder: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        // Enum cells carry the label text in both wire formats.
        let label = byteBuffer.readString(length: byteBuffer.readableBytes) ?? ""
        guard let value = Self(rawValue: label) else {
            throw HangarError.invalidEnumValue(type: String(describing: Self.self), value: label)
        }
        self = value
    }
}

extension PostgresDataType {
    /// `unknown` (OID 705): the server infers the parameter's type from
    /// context, as it does for untyped text literals.
    @usableFromInline
    static let unknownOID = PostgresDataType(705)
}

/// Text sent with the `unknown` type OID — the carrier for JSONB payloads
/// (and anything else whose Postgres type only the server knows).
@usableFromInline
struct UnknownText: PostgresDynamicTypeEncodable {
    @usableFromInline let value: String
    @usableFromInline init(value: String) { self.value = value }

    @usableFromInline var psqlType: PostgresDataType { .unknownOID }
    @usableFromInline var psqlFormat: PostgresFormat { .text }

    @usableFromInline
    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(value)
    }
}

// MARK: - SQLBind

/// One bound statement parameter, type-erased. Values are captured at AST
/// construction and applied to `PostgresBindings` at execution — always as
/// parameters, never interpolated into SQL.
public struct SQLBind: Sendable {
    @usableFromInline
    let apply: @Sendable (inout PostgresBindings) throws -> Void

    @usableFromInline
    init(apply: @Sendable @escaping (inout PostgresBindings) throws -> Void) {
        self.apply = apply
    }

    @inlinable
    /// Binds one value as a `$n` parameter.
    public init<V: ColumnCodable>(_ value: V) {
        self.init { try $0.append(value) }
    }

    @inlinable
    /// Binds an optional value; nil binds SQL NULL.
    public init<V: ColumnCodable>(_ value: V?) {
        self.init { try $0.append(value) }
    }

    /// A `@JSONB` column's value: JSON-encoded at execution time and sent as
    /// `unknown`-typed text so the server coerces it to `jsonb`.
    public init<V: Encodable & Sendable>(jsonb value: V) {
        self.init {
            let data = try JSONCoders.encoder.encode(value)
            $0.append(UnknownText(value: String(decoding: data, as: UTF8.self)))
        }
    }

    /// The optional `@JSONB` bind; nil binds SQL NULL.
    public init<V: Encodable & Sendable>(jsonb value: V?) {
        if let value {
            self.init(jsonb: value)
        } else {
            self.init { $0.appendNull() }
        }
    }
}

/// One encoder/decoder pair for all `@JSONB` traffic. Constructing a
/// `JSONEncoder`/`JSONDecoder` per value is surprisingly expensive — it
/// showed up as a measurable share of per-row decode cost — and both are
/// documented as safe for concurrent use once configured, which is why
/// sharing them is sound rather than merely convenient.
enum JSONCoders {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

// MARK: - Row decoding helpers (called by @Entity-generated code)

/// Underscored helpers below are referenced by `@Entity`'s generated
/// expansion and are public only for that reason — they are not user API.

@inlinable
/// Called by `@Entity`'s generated decoder — not user API.
public func _checkColumnCount(_ count: Int, expected: Int, table: String) throws {
    guard count == expected else {
        throw HangarError.columnCountMismatch(table: table, expected: expected, got: count)
    }
}

/// Called by `@Entity`'s generated decoder — not user API. Wraps a
/// cell decode failure with the table and column it happened on.
public func _decodeColumn<V: PostgresDecodable>(
    _ type: V.Type,
    from cell: PostgresCell,
    table: String,
    column: String
) throws -> V {
    do {
        return try cell.decode(type)
    } catch {
        throw HangarError.columnDecoding(table: table, column: column, underlying: error)
    }
}

/// Called by `@Entity`'s generated decoder — not user API.
public func _decodeJSONB<V: Decodable>(
    _ type: V.Type,
    from cell: PostgresCell,
    table: String,
    column: String
) throws -> V {
    guard let value = try _decodeOptionalJSONB(type, from: cell, table: table, column: column)
    else {
        throw HangarError.jsonb(
            table: table, column: column,
            underlying: PostgresDecodingError.Code.missingData)
    }
    return value
}

/// Called by `@Entity`'s generated decoder — not user API.
public func _decodeOptionalJSONB<V: Decodable>(
    _ type: V.Type,
    from cell: PostgresCell,
    table: String,
    column: String
) throws -> V? {
    guard var buffer = cell.bytes else { return nil }
    // Binary-format jsonb cells lead with a wire-format version byte
    // (SPIKE-FINDINGS S4); the rest is JSON text in either format.
    if cell.dataType == .jsonb, cell.format == .binary {
        _ = buffer.readInteger(as: UInt8.self)
    }
    let data = buffer.readData(length: buffer.readableBytes) ?? Data()
    do {
        return try JSONCoders.decoder.decode(V.self, from: data)
    } catch {
        throw HangarError.jsonb(table: table, column: column, underlying: error)
    }
}
