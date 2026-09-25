import Foundation
import PostgresNIO

/// An error the database server reported, classified.
///
/// Every server-side failure a `Repo` sees arrives as this type rather than
/// as PostgresNIO's `PSQLError`, for two reasons.
///
/// **The common cases are typed.** A duplicate email is `.uniqueViolation`
/// with the constraint and the columns that collided, so a form handler can
/// fold it back into a changeset without knowing SQLSTATE codes:
///
/// ```swift
/// do {
///     try await repo.insert(changeset.validatedChanges())
/// } catch let error as DatabaseError where error.isUniqueViolation {
///     return changeset.addError(\.email, "has already been taken")
/// }
/// ```
///
/// **It is safe to log.** `PSQLError` redacts its description, so a logged
/// failure reads as a generic placeholder. The opposite mistake is just as
/// easy: the server's text quotes data. The detail of a unique violation
/// quotes the row (`Key (email)=(ada@example.com) already exists`), the
/// primary message of a bad cast quotes the value (`invalid input syntax for
/// type integer: "…"`), and a trigger's `RAISE` can say anything.
/// `description` is therefore metadata only — kind, SQLSTATE, table,
/// constraint and column *names* — except for an error about the statement
/// itself (class 42, class 0A), whose message names only what the SQL names.
/// The server's words stay reachable as ``message`` and ``underlying`` for
/// code that deliberately wants them.
public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    /// The classes of server error Hangar distinguishes.
    public enum Kind: Sendable, Equatable {
        /// SQLSTATE 23505: a unique constraint or unique index rejected the row.
        case uniqueViolation
        /// SQLSTATE 23503: a foreign key has no matching row, or a referenced
        /// row is still referenced.
        case foreignKeyViolation
        /// SQLSTATE 23514: a `CHECK` constraint rejected the row.
        case checkViolation
        /// SQLSTATE 23502: a `NOT NULL` column was given NULL.
        case notNullViolation
        /// SQLSTATE 23P01: an exclusion constraint rejected the row.
        case exclusionViolation
        /// SQLSTATE 40001: a serializable transaction lost a conflict and
        /// must be retried.
        case serializationFailure
        /// SQLSTATE 40P01: the transaction was chosen as a deadlock victim.
        case deadlock
        /// SQLSTATE 55P03: `NOWAIT` (or `lock_timeout`) could not take a lock.
        case lockNotAvailable
        /// SQLSTATE 57014: `statement_timeout` expired or the query was
        /// cancelled.
        case queryCanceled
        /// SQLSTATE 22003: a number too large (or small) for its type — an
        /// integer sum past `bigint`, a value past `smallint`.
        case numericValueOutOfRange
        /// SQLSTATE 25P02: an earlier statement in this transaction failed,
        /// so Postgres ignores everything until the transaction ends.
        case transactionAborted
        /// Anything else. ``sqlState`` says which.
        case other
    }

    public let kind: Kind
    /// The five-character SQLSTATE, e.g. `"23505"`.
    public let sqlState: String
    /// The server's primary message. **May contain data**: a failed cast
    /// quotes the value (`invalid input syntax for type integer: "…"`), and a
    /// trigger's `RAISE` can say anything. Part of ``description`` only for
    /// class 42 and 0A, which are about the statement's own text.
    public let message: String
    /// The table the error concerns, when the server names one.
    public let table: String?
    /// The constraint that failed, when the server names one.
    public let constraint: String?
    /// The columns involved, by name only — never their values.
    ///
    /// For `NOT NULL` violations this is the server's column field. For
    /// unique and foreign-key violations Postgres names no column field; the
    /// names are read from the key list in its detail (`Key (a, b)=(…)`),
    /// and the values that follow are discarded.
    public let columns: [String]
    /// The complete error PostgresNIO produced, including the server detail
    /// — which may quote row values. Read it deliberately; do not log it.
    public let underlying: PSQLError

    /// The single column involved, when there is exactly one.
    public var columnName: String? { columns.count == 1 ? columns[0] : nil }

    public var isUniqueViolation: Bool { kind == .uniqueViolation }
    public var isForeignKeyViolation: Bool { kind == .foreignKeyViolation }
    public var isCheckViolation: Bool { kind == .checkViolation }
    public var isNotNullViolation: Bool { kind == .notNullViolation }
    /// True for every integrity-constraint violation (SQLSTATE class 23).
    public var isConstraintViolation: Bool { sqlState.hasPrefix("23") }
    /// SQLSTATE 40001 or 40P01: the answers Postgres gives when running the
    /// transaction again is the documented remedy.
    public var isRetryable: Bool { kind == .serializationFailure || kind == .deadlock }

    /// Classifies a server error. `nil` for errors that never reached the
    /// server (connection failures, client-side limits, decoding), which
    /// keep their own types.
    public init?(_ error: PSQLError) {
        guard let server = error.serverInfo, let state = server[.sqlState] else { return nil }
        self.sqlState = state
        self.kind = Self.kind(for: state)
        self.message = server[.message] ?? ""
        self.table = server[.tableName]
        self.constraint = server[.constraintName]
        if let column = server[.columnName] {
            self.columns = [column]
        } else {
            self.columns = Self.keyColumns(fromDetail: server[.detail])
        }
        self.underlying = error
    }

    public var description: String {
        var parts = ["\(Self.name(of: kind)) (SQLSTATE \(sqlState))"]
        if let statementMessage { parts[0] += ": \(statementMessage)" }
        if let table { parts.append("table \"\(table)\"") }
        if let constraint { parts.append("constraint \"\(constraint)\"") }
        if !columns.isEmpty {
            parts.append("column\(columns.count == 1 ? "" : "s") \(columns.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    static func kind(for sqlState: String) -> Kind {
        switch sqlState {
        case "23505": .uniqueViolation
        case "23503": .foreignKeyViolation
        case "23514": .checkViolation
        case "23502": .notNullViolation
        case "23P01": .exclusionViolation
        case "40001": .serializationFailure
        case "40P01": .deadlock
        case "55P03": .lockNotAvailable
        case "57014": .queryCanceled
        case "22003": .numericValueOutOfRange
        case "25P02": .transactionAborted
        default: .other
        }
    }

    /// The server's message, when the error is about the statement itself.
    ///
    /// Class 42 (a syntax error, an undefined column, function or table) and
    /// class 0A (a feature not supported) describe the SQL the programmer
    /// wrote, and "SQLSTATE 42703" without "column \"nmae\" does not exist" is
    /// an error nobody can act on (Relay #17). The message can name only what
    /// the statement names — and the statement's text is already in the
    /// failure log — so it is included for these classes and no others.
    var statementMessage: String? {
        guard sqlState.hasPrefix("42") || sqlState.hasPrefix("0A"), !message.isEmpty else { return nil }
        return message
    }

    /// The kind in words, e.g. `unique violation`.
    public var kindName: String { Self.name(of: kind) }

    private static func name(of kind: Kind) -> String {
        switch kind {
        case .uniqueViolation: "unique violation"
        case .foreignKeyViolation: "foreign key violation"
        case .checkViolation: "check violation"
        case .notNullViolation: "not-null violation"
        case .exclusionViolation: "exclusion violation"
        case .serializationFailure: "serialization failure"
        case .deadlock: "deadlock"
        case .lockNotAvailable: "lock not available"
        case .queryCanceled: "query canceled"
        case .numericValueOutOfRange: "numeric value out of range"
        case .transactionAborted: "transaction aborted"
        case .other: "database error"
        }
    }

    /// The column names from a detail of the form `Key (a, "b c")=(…) …`.
    ///
    /// Only the parenthesised list before `=` is read; the values after it
    /// are never touched. Postgres prints each column the way it would in
    /// SQL — bare, or double-quoted with embedded quotes doubled — and
    /// expression indexes print expressions (`lower(email)`), which are
    /// returned as written. Anything that does not have this shape yields
    /// no columns rather than a guess.
    static func keyColumns(fromDetail detail: String?) -> [String] {
        guard let detail, detail.hasPrefix("Key (") else { return [] }
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var index = detail.index(detail.startIndex, offsetBy: 5)
        while index < detail.endIndex {
            let character = detail[index]
            let next = detail.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < detail.endIndex, detail[next] == "\"" {
                        current.append("\"")
                        index = detail.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case "(":
                    depth += 1
                    current.append(character)
                case ")" where depth > 0:
                    depth -= 1
                    current.append(character)
                case ")":
                    // The list closed; it must be followed by `=` to be a key list.
                    guard next < detail.endIndex, detail[next] == "=" else { return [] }
                    columns.append(current.trimmingCharacters(in: .whitespaces))
                    return columns.contains(where: \.isEmpty) ? [] : columns
                case "," where depth == 0:
                    columns.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                default:
                    current.append(character)
                }
            }
            index = next
        }
        return []
    }
}

/// Wraps server errors as ``DatabaseError``; everything else passes through.
func translatingDatabaseErrors(_ error: any Error) -> any Error {
    if let psql = error as? PSQLError, let classified = DatabaseError(psql) { return classified }
    return error
}
