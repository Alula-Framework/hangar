import PostgresNIO

/// The rows a statement returns, read with Hangar's error handling.
///
/// A drop-in for PostgresNIO's `PostgresRowSequence` — iterate it, or
/// `decode` it — that exists because of *when* Postgres reports a failure.
/// Sending a statement can succeed and the failure arrive with the rows: an
/// `INSERT … RETURNING` that violates a unique constraint, or a `SELECT`
/// that divides by zero on row one thousand. Errors raised here get the same
/// treatment as errors raised on sending — they become ``DatabaseError``,
/// are recorded against the enclosing transaction, and are reported once.
public struct DatabaseRows: AsyncSequence, Sendable {
    public typealias Element = PostgresRow

    let base: PostgresRowSequence
    let failed: @Sendable (any Error) -> any Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: PostgresRowSequence.AsyncIterator
        let failed: @Sendable (any Error) -> any Error

        public mutating func next() async throws -> PostgresRow? {
            do {
                return try await base.next()
            } catch {
                throw failed(error)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), failed: failed)
    }

    /// The result's columns, as the server described them.
    public var columns: PostgresColumns { base.columns }

    /// Every row, in order.
    public func collect() async throws -> [PostgresRow] {
        var rows: [PostgresRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }
}
