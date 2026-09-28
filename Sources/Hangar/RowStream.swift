import PostgresNIO
import Synchronization

/// A lazily-decoded result set: rows arrive from the server and decode one
/// at a time, so memory stays flat regardless of how many there are.
///
/// Obtained from `repo.stream(query) { ... }`, and valid only inside that
/// closure — the connection is leased for the stream's lifetime, which is
/// what bounds it. The value itself can be copied out of the closure (it is
/// an ordinary `Sendable` struct, and Swift's `AsyncSequence` cannot be
/// conformed to by a non-escapable type), so escaping is not a compile
/// error — but iterating an escaped stream throws
/// `HangarError.streamLeaseExpired` on the first `next()` rather than
/// reading from a connection some other query now owns.
///
/// **The connection is held while you iterate.** Anything slow inside the
/// loop — a network write, a call to another service — holds it too. From a
/// pooled repo that is one pooled connection per open stream; a repo inside
/// a transaction, or pinned with `Repo(connection:)`, streams on its own
/// connection.
///
/// **Leaving early is supported.** Returning or throwing from the closure
/// before the last row ends the stream: the remaining rows are never
/// decoded, and PostgresNIO reads the rest of the result off the wire and
/// discards it. No cancel request reaches the server, so it still
/// produces the whole result; bound the query with `limit` if you only want
/// the head. Cancelling the iterating task ends the stream the same way — a
/// `next()` waiting for rows throws `CancellationError`.
///
/// Preloads are not applied: batching them needs every parent row at once,
/// which is what streaming declines to hold.
public struct PostgresRowStream<Element: Sendable>: AsyncSequence, Sendable {
    let rows: DatabaseRows
    let decode: @Sendable (PostgresRow) throws -> Element
    let lease: StreamLease

    /// Decodes one row per `next()`, while the lease is live.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: DatabaseRows.AsyncIterator
        let decode: @Sendable (PostgresRow) throws -> Element
        let lease: StreamLease

        /// The next decoded row, or `nil` after the last one.
        ///
        /// Throws ``HangarError/streamLeaseExpired`` once the `stream { }`
        /// closure has returned, a ``DatabaseError`` when the server fails
        /// the statement partway (a division by zero on row one thousand),
        /// and whatever the row's decoding throws.
        public mutating func next() async throws -> Element? {
            guard !lease.isExpired else {
                throw HangarError.streamLeaseExpired
            }
            guard let row = try await base.next() else { return nil }
            return try decode(row)
        }
    }

    /// An iterator sharing this stream's lease.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: rows.makeAsyncIterator(), decode: decode, lease: lease)
    }
}

/// The validity of one `stream { }` call's connection lease: live while the
/// body runs, expired the moment it returns. Checked by the iterator so a
/// stream that escaped its closure fails loudly at the point of misuse
/// instead of reading rows from a connection that has moved on.
final class StreamLease: Sendable {
    private let state = Mutex(false)

    var isExpired: Bool {
        state.withLock { $0 }
    }

    func expire() {
        state.withLock { $0 = true }
    }
}
