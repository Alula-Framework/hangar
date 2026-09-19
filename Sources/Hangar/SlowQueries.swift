import Logging
import Synchronization

/// What counts as slow, and what to do about it.
///
/// Timing every statement is already free — `Repo` records a
/// `hangar.query.duration` timer regardless. What a metric cannot tell you is
/// *which* statement is slow: a dashboard shows a p99 climbing and leaves you
/// to guess. This turns the same measurement into a log line naming the SQL.
///
/// Off by default. A threshold that fires on every query is noise, and one
/// that never fires is a setting nobody tuned — so it is opt-in with a value
/// the caller chose:
///
///     var repo = Repo(client: pool, logger: logger)
///     repo.diagnostics = .init(slowQueryThreshold: .milliseconds(200))
public struct QueryDiagnostics: Sendable {
    /// Statements at or above this take a warning log naming the SQL.
    /// `nil` disables the check.
    public var slowQueryThreshold: Duration?

    /// Warn when one statement shape runs this many times inside a single
    /// `detectingRepeatedQueries` block — the shape of an N+1.
    /// `nil` disables the check.
    public var repeatedQueryThreshold: Int?

    public init(slowQueryThreshold: Duration? = nil, repeatedQueryThreshold: Int? = nil) {
        self.slowQueryThreshold = slowQueryThreshold
        self.repeatedQueryThreshold = repeatedQueryThreshold
    }

    /// Sensible starting points rather than an invitation to invent numbers:
    /// 200ms is slow for an indexed OLTP query, and twenty identical
    /// statements in one unit of work is a loop that should have been a
    /// preload.
    public static let recommended = QueryDiagnostics(
        slowQueryThreshold: .milliseconds(200), repeatedQueryThreshold: 20)
}

/// Counts statement shapes for the duration of one unit of work.
///
/// An N+1 is invisible per-statement — every query is fast, there are just
/// hundreds of them. It only shows up when you count the same SQL repeating,
/// and only within a bounded scope: the same statement running once per
/// request all day is fine, a hundred times in one request is not.
final class RepeatedQueryCounter: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    /// Bound to the unit of work being measured, so counting stops at its
    /// edge rather than accumulating across a process's lifetime.
    @TaskLocal static var current: RepeatedQueryCounter?

    /// Returns the running count for this SQL after recording it.
    func record(_ sql: String) -> Int {
        counts.withLock { counts in
            let next = (counts[sql] ?? 0) + 1
            counts[sql] = next
            return next
        }
    }

    var summary: [(sql: String, count: Int)] {
        counts.withLock { $0.map { (sql: $0.key, count: $0.value) }.sorted { $0.count > $1.count } }
    }
}

extension Repo {
    /// Counts statement shapes across `body`, and warns about any that ran
    /// more than `repeatedQueryThreshold` times.
    ///
    ///     try await repo.detectingRepeatedQueries {
    ///         try await renderDashboard()
    ///     }
    ///
    /// Wrap the unit of work you suspect — a request handler, a job — rather
    /// than the whole process. Repetition is only meaningful against a scope.
    @discardableResult
    public func detectingRepeatedQueries<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard let threshold = diagnostics.repeatedQueryThreshold else { return try await body() }
        let counter = RepeatedQueryCounter()
        let result = try await RepeatedQueryCounter.$current.withValue(counter) {
            try await body()
        }
        for entry in counter.summary where entry.count >= threshold {
            diagnosticsLogger.warning(
                "hangar repeated query",
                metadata: [
                    "sql": .string(entry.sql),
                    "count": .stringConvertible(entry.count),
                    "hint": .string(
                        "the same statement ran \(entry.count) times in one unit of work — a preload or a join usually replaces this"
                    ),
                ])
        }
        return result
    }

    /// Where a diagnostic goes when the repo was built without a logger.
    ///
    /// A `Repo` carries an optional logger, and both reports above used to be
    /// `logger?.warning(...)` — so a repo constructed without one discarded
    /// them. That is every repo `flight-data`'s `withRepo` builds, which is
    /// the idiom its own documentation recommends: an application could set
    /// `diagnostics = .recommended`, run thirty copies of one statement
    /// inside `detectingRepeatedQueries`, and get silence.
    ///
    /// Diagnostics are opt-in and exist to be read. Statement *tracing* still
    /// respects the optional logger — a repo with none stays quiet at debug
    /// level — but a threshold the caller deliberately set reports through a
    /// package logger rather than into nothing.
    var diagnosticsLogger: Logger { logger ?? Logger(label: "hangar.diagnostics") }

    /// Called from the execute funnel once a statement's duration is known.
    func reportDiagnostics(sql: String, operation: String, duration: Duration) {
        if let threshold = diagnostics.slowQueryThreshold, duration >= threshold {
            diagnosticsLogger.warning(
                "hangar slow query",
                metadata: [
                    "sql": .string(sql),
                    "operation": .string(operation),
                    "duration_ms": .stringConvertible(duration.milliseconds),
                    "threshold_ms": .stringConvertible(threshold.milliseconds),
                ])
        }
        if let counter = RepeatedQueryCounter.current {
            _ = counter.record(sql)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
