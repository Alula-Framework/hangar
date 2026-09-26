import Foundation
import PostgresNIO

/// The database could not be reached, or the connection was lost.
///
/// A statement that fails on the server is a ``DatabaseError``. One that
/// never got an answer — the server refused the connection, the network
/// dropped it, TLS or authentication could not be set up, the pool was shut
/// down — used to reach the caller as PostgresNIO's `PSQLError`, whose
/// description is deliberately opaque ("Generic description to prevent
/// accidental leakage of sensitive data"). A queue worker's log then said
/// only that for "could not claim jobs" (Relay #43).
///
/// This says what happened, in terms an operator acts on and without
/// anything that can carry data: the kind, and the system's reason
/// (`connection refused (127.0.0.1:5432)`, `connection reset by peer`).
///
/// ```swift
/// do {
///     try await repo.all(Incident.self)
/// } catch let error as DatabaseConnectionError where error.isTransient {
///     return .serviceUnavailable   // 503: worth retrying later
/// }
/// ```
public struct DatabaseConnectionError: Error, Sendable, CustomStringConvertible {
    /// What went wrong with the connection.
    public enum Kind: Sendable, Equatable {
        /// A new connection could not be made: refused, unresolvable, timed
        /// out, or the pool has stopped trying after repeated failures.
        case unreachable
        /// An open connection was closed by the server or the network.
        case connectionLost
        /// TLS could not be set up as configured.
        case tls
        /// The server asked for an authentication method the client cannot
        /// answer, or SASL failed. (A wrong password is a server error:
        /// ``DatabaseError`` with SQLSTATE 28P01.)
        case authentication
        /// The pool, or this connection, was closed by the application —
        /// normally during shutdown.
        case closed
    }

    public let kind: Kind
    /// The system's reason, cut down to what an operator reads, e.g.
    /// `connection refused (127.0.0.1:5432)`. Never carries bound values.
    public let reason: String
    /// The error PostgresNIO produced. Read it deliberately.
    public let underlying: any Error

    /// Whether trying again later can succeed: true for a server that is
    /// down or a connection that dropped, false for a TLS or authentication
    /// setup the server will refuse again, or a pool the application closed.
    public var isTransient: Bool { kind == .unreachable || kind == .connectionLost }

    public var description: String {
        let what =
            switch kind {
            case .unreachable: "could not connect to the database"
            case .connectionLost: "the database connection was lost"
            case .tls: "the database connection's TLS setup failed"
            case .authentication: "could not authenticate to the database"
            case .closed: "the database connection pool is closed"
            }
        return reason.isEmpty ? what : "\(what): \(reason)"
    }

    /// Classifies a failure that never reached the server. `nil` for server
    /// errors (``DatabaseError``) and for client-side failures that are not
    /// about the connection — a decode, too many parameters, a cancelled
    /// query.
    public init?(_ error: any Error) {
        if let psql = error as? PSQLError {
            guard psql.serverInfo == nil, let kind = Self.kind(for: psql.code) else { return nil }
            self.kind = kind
            self.reason = psql.underlying.map { readableConnectionFailure("\($0)") } ?? ""
            self.underlying = psql
            return
        }
        // PostgresNIO passes the pool's circuit breaker through as
        // `_ConnectionPoolModule.ConnectionPoolError`, an underscored module
        // Hangar does not import; it is recognised by name.
        let type = String(reflecting: Swift.type(of: error))
        if type.hasSuffix("ConnectionPoolError"), "\(error)".contains("CircuitBreaker") {
            self.kind = .unreachable
            self.reason = "repeated connection attempts failed"
            self.underlying = error
            return
        }
        return nil
    }

    static func kind(for code: PSQLError.Code) -> Kind? {
        switch code {
        case .connectionError: .unreachable
        case .serverClosedConnection, .uncleanShutdown: .connectionLost
        case .sslUnsupported, .failedToAddSSLHandler, .receivedUnencryptedDataAfterSSLRequest: .tls
        case .unsupportedAuthMechanism, .authMechanismRequiresPassword, .saslError: .authentication
        case .poolClosed, .clientClosedConnection: .closed
        default: nil
        }
    }
}

/// PostgresNIO's text for a failed connection, cut down to what an operator
/// reads.
///
/// A refused connection arrives as
/// `Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:1,
/// error: connection reset (error set): Connection refused) (errno: 111))`.
/// This returns `connection refused (127.0.0.1:1)`, one entry per address
/// tried, or `connection reset by peer` for a failure on a connection that
/// was already open. Text in any other shape comes back unchanged, so a
/// format this does not know costs polish, never information.
func readableConnectionFailure(_ text: String) -> String {
    let pattern = #/target: \[[^\]]*\][^\/,]*\/([^,]+), error: (.*?)\(errno: \d+\)/#
    let failures = text.matches(of: pattern).map { match -> String in
        let error = String(match.output.2)
        let reason = error.components(separatedBy: ": ").last ?? error
        let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: ") "))
        return "\(trimmed.lowercased()) (\(match.output.1))"
    }
    if !failures.isEmpty { return failures.joined(separator: "; ") }
    if let match = text.firstMatch(of: #/:\s*([A-Za-z][^:()]*?)\)?\s*\(errno: \d+\)/#) {
        return match.output.1.lowercased()
    }
    return text
}
