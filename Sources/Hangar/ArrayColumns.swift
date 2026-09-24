import NIOCore
import PostgresNIO

// Two array shapes PostgresNIO's array coding cannot carry, and Postgres
// columns routinely hold:
//
// - NULL *elements* (`{1,NULL,3}`). PostgresNIO decodes an array only when
//   its has-null flag is clear, so one NULL anywhere made the whole row
//   undecodable.
// - Arrays of a Postgres enum (`role[]`). An enum's type OID is assigned per
//   database, so there is no static array type to encode against.
//
// Both are plain collections at the use site and ColumnCodable, so they go
// in an `@Entity` like any other column type.

/// An array column whose elements may be NULL — `[Int?]` for a `bigint[]`.
///
/// ```swift
/// @Entity("readings")
/// struct Reading {
///     @ID var id: UUID
///     var samples: NullableArray<Double>     // double precision[]
/// }
/// ```
public struct NullableArray<Element>: Sendable, Equatable, Hashable, ColumnCodable, RandomAccessCollection,
    ExpressibleByArrayLiteral
where
    Element: PostgresArrayEncodable & PostgresArrayDecodable & Sendable & Hashable,
    Element == Element._DecodableType
{
    public var elements: [Element?]

    public init(_ elements: [Element?]) { self.elements = elements }
    public init(arrayLiteral elements: Element?...) { self.elements = elements }

    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(position: Int) -> Element? { elements[position] }

    public static var psqlType: PostgresDataType { Element.psqlArrayType }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) throws {
        buffer.writeInteger(Int32(elements.isEmpty ? 0 : 1), as: Int32.self)  // dimensions
        buffer.writeInteger(Int32(elements.contains(nil) ? 1 : 0), as: Int32.self)  // has NULLs
        buffer.writeInteger(Element.psqlType.rawValue, as: UInt32.self)
        guard !elements.isEmpty else { return }
        buffer.writeInteger(Int32(elements.count), as: Int32.self)
        buffer.writeInteger(Int32(1), as: Int32.self)  // lower bound
        for element in elements {
            guard let element else {
                buffer.writeInteger(Int32(-1), as: Int32.self)
                continue
            }
            var cell = ByteBuffer()
            try element.encode(into: &cell, context: context)
            buffer.writeInteger(Int32(cell.readableBytes), as: Int32.self)
            buffer.writeBuffer(&cell)
        }
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        self.elements = try decodeBinaryArray(from: &buffer, format: format) { cell, elementType in
            guard var cell else { return nil }
            return try Element(from: &cell, type: elementType, format: .binary, context: context)
        }
    }
}

/// An array of a Postgres enum — `EnumArray<Role>` for a `role[]` column.
///
/// ```swift
/// enum Role: String, PostgresEnum { case reader, editor, admin }
///
/// @Entity("members")
/// struct Member {
///     @ID var id: UUID
///     var roles: EnumArray<Role>             // role[]
/// }
/// ```
///
/// Written as an array literal the server types from the column (the way a
/// single enum value is sent), read back in either wire format. Elements are
/// never NULL; a NULL element or an unknown label throws.
public struct EnumArray<Element: PostgresEnum & Hashable>: Sendable, Equatable, Hashable, ColumnCodable,
    RandomAccessCollection, ExpressibleByArrayLiteral
{
    public var elements: [Element]

    public init(_ elements: [Element]) { self.elements = elements }
    public init(arrayLiteral elements: Element...) { self.elements = elements }

    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(position: Int) -> Element { elements[position] }

    /// `unknown` (OID 705): the server infers `role[]` from the column.
    public static var psqlType: PostgresDataType { .unknownOID }
    public static var psqlFormat: PostgresFormat { .text }

    public func encode<JSONEncoder: PostgresJSONEncoder>(
        into buffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        buffer.writeString(arrayLiteral(elements.map(\.rawValue)))
    }

    public init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        let labels: [String?]
        switch format {
        case .binary:
            labels = try decodeBinaryArray(from: &buffer, format: format) { cell, _ in
                guard var cell else { return nil }
                return cell.readString(length: cell.readableBytes) ?? ""
            }
        case .text:
            labels = try parseArrayLiteral(buffer.readString(length: buffer.readableBytes) ?? "")
        }
        self.elements = try labels.map { label in
            guard let label else {
                throw HangarError.invalidEnumValue(type: String(describing: Element.self), value: "NULL")
            }
            guard let value = Element(rawValue: label) else {
                throw HangarError.invalidEnumValue(type: String(describing: Element.self), value: label)
            }
            return value
        }
    }
}

// MARK: - Wire formats

/// Reads a one-dimensional array in Postgres's binary format, handing each
/// cell (nil for NULL) to `element` with the array's element type.
func decodeBinaryArray<T>(
    from buffer: inout ByteBuffer, format: PostgresFormat,
    element: (ByteBuffer?, PostgresDataType) throws -> T
) throws -> [T] {
    guard case .binary = format,
        let (dimensions, _, elementOID) = buffer.readMultipleIntegers(endianness: .big, as: (Int32, Int32, UInt32).self)
    else { throw PostgresDecodingError.Code.failure }
    guard dimensions != 0 else { return [] }
    guard dimensions == 1,
        let (count, _) = buffer.readMultipleIntegers(endianness: .big, as: (Int32, Int32).self), count >= 0
    else {
        // Multidimensional arrays have no Swift shape here.
        throw PostgresDecodingError.Code.failure
    }
    let elementType = PostgresDataType(elementOID)
    var result: [T] = []
    result.reserveCapacity(Int(count))
    for _ in 0..<count {
        guard let length = buffer.readInteger(endianness: .big, as: Int32.self) else {
            throw PostgresDecodingError.Code.failure
        }
        if length < 0 {
            result.append(try element(nil, elementType))
        } else {
            guard let cell = buffer.readSlice(length: Int(length)) else { throw PostgresDecodingError.Code.failure }
            result.append(try element(cell, elementType))
        }
    }
    return result
}

/// `{"a","b c"}` — every element double-quoted with `"` and `\` escaped, so
/// no label (not even one spelled `NULL`, or holding a comma or brace) can
/// change the array's shape.
func arrayLiteral(_ elements: [String]) -> String {
    let quoted = elements.map { element -> String in
        var escaped = "\""
        for character in element {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped + "\""
    }
    return "{" + quoted.joined(separator: ",") + "}"
}

/// Parses a one-dimensional array in Postgres's text format. An unquoted
/// `NULL` is a NULL element; a quoted `"NULL"` is the text.
func parseArrayLiteral(_ text: String) throws -> [String?] {
    var characters = Substring(text)
    guard characters.first == "{", characters.last == "}" else { throw PostgresDecodingError.Code.failure }
    characters = characters.dropFirst().dropLast()
    guard !characters.isEmpty else { return [] }
    var result: [String?] = []
    var index = characters.startIndex
    while index <= characters.endIndex {
        var element = ""
        var quoted = false
        if index < characters.endIndex, characters[index] == "\"" {
            quoted = true
            index = characters.index(after: index)
            while index < characters.endIndex, characters[index] != "\"" {
                if characters[index] == "\\" { index = characters.index(after: index) }
                guard index < characters.endIndex else { throw PostgresDecodingError.Code.failure }
                element.append(characters[index])
                index = characters.index(after: index)
            }
            guard index < characters.endIndex else { throw PostgresDecodingError.Code.failure }
            index = characters.index(after: index)
        } else {
            while index < characters.endIndex, characters[index] != "," {
                if characters[index] == "{" { throw PostgresDecodingError.Code.failure }  // nested
                element.append(characters[index])
                index = characters.index(after: index)
            }
        }
        result.append(!quoted && element == "NULL" ? nil : element)
        guard index < characters.endIndex else { break }
        guard characters[index] == "," else { throw PostgresDecodingError.Code.failure }
        index = characters.index(after: index)
    }
    return result
}
