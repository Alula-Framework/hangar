import Foundation
import PostgresNIO

/// Decodes a `select(into:)` projection row into a `Decodable` type:
/// each labeled tuple element renders as `expr AS "label"`, and the type's
/// synthesized `Decodable` conformance reads cells by those names.
///
/// Scope note: this is DTO decoding, deliberately narrower than a general
/// `Decoder` — flat keyed fields whose types are PostgresNIO-decodable
/// (plus `Codable` fields backed by json/jsonb cells). Nested containers
/// and unkeyed collections aren't columns and are refused with a clear
/// error. Unlike `@Entity` rows (positional, compile-time generated),
/// projections into named types inherently key by column name.
struct ProjectionDecoder: Decoder {
    let row: PostgresRandomAccessRow
    let table: String

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(ProjectionKeyedContainer<Key>(row: row, table: table))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription:
                    "A projection row decodes keyed fields, not an unkeyed collection."))
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription: "A projection row decodes keyed fields, not a single value."))
    }
}

private struct ProjectionKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: PostgresRandomAccessRow
    let table: String

    var codingPath: [any CodingKey] { [] }
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool {
        row.contains(key.stringValue)
    }

    private func cell(for key: Key) throws -> PostgresCell {
        guard row.contains(key.stringValue) else {
            throw DecodingError.keyNotFound(
                key,
                .init(
                    codingPath: [],
                    debugDescription:
                        "The SELECT list has no column aliased \"\(key.stringValue)\"."))
        }
        return row[key.stringValue]
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try cell(for: key).bytes == nil
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decodeValue(type, forKey: key)
    }

    private func decodeValue<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let cell = try cell(for: key)
        // PostgresNIO-decodable field types read straight off the cell.
        if let postgresType = T.self as? any PostgresDecodable.Type {
            guard let value = try decodeCell(postgresType, from: cell, key: key) as? T else {
                throw mismatch(type, key)
            }
            return value
        }
        // Codable fields backed by json/jsonb cells.
        if cell.dataType == .jsonb || cell.dataType == .json {
            return try _decodeJSONB(T.self, from: cell, table: table, column: key.stringValue)
        }
        throw mismatch(type, key)
    }

    private func decodeCell<P: PostgresDecodable>(
        _ type: P.Type, from cell: PostgresCell, key: Key
    ) throws -> P {
        try _decodeColumn(P.self, from: cell, table: table, column: key.stringValue)
    }

    private func mismatch(_ type: any Any.Type, _ key: Key) -> DecodingError {
        DecodingError.typeMismatch(
            type,
            .init(
                codingPath: [key],
                debugDescription:
                    "\"\(key.stringValue)\" (\(type)) is not decodable from a projection cell — supported: PostgresNIO-decodable types and Codable values in json/jsonb columns."
            ))
    }

    // The fixed-type requirements route through the generic path.
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeValue(type, forKey: key)
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { throw mismatch(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { throw mismatch(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { throw mismatch(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { throw mismatch(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { throw mismatch(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { throw mismatch(type, key) }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw mismatch([String: Any].self, key)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw mismatch([Any].self, key)
    }

    func superDecoder() throws -> any Decoder {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Projection rows have no super."))
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [key], debugDescription: "Projection rows have no super."))
    }
}
