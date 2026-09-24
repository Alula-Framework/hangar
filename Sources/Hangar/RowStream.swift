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
public struct PostgresRowStream<Element: Sendable>: AsyncSequence, Sendable {
    let rows: DatabaseRows
    let decode: @Sendable (PostgresRow) throws -> Element
    let lease: StreamLease

    /// Decodes one row per `next()`, while the lease is live.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: DatabaseRows.AsyncIterator
        let decode: @Sendable (PostgresRow) throws -> Element
        let lease: StreamLease

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
