import Changesets

// `Multi` — transaction orchestration with typed keys.
// Steps are values: a Multi can be built conditionally, returned from a
// function, and passed around before it runs. Later steps see earlier
// results through the closure parameter; everything runs in one
// transaction, and any failure rolls back all of it.

/// A phantom-typed key naming one step's result. Internally results are
/// `[String: any Sendable]`; the key carries the value's type, which makes
/// the subscript's cast safe, so the erasure never surfaces in user code.
public struct MultiKey<Value: Sendable>: Sendable, CustomStringConvertible {
    /// The key's name — how results are stored and reported.
    public let name: String

    /// Creates a key. Names must be unique within one Multi.
    public init(_ name: String) {
        self.name = name
    }

    /// The key's name.
    public var description: String { name }
}

/// The results accumulated so far — what step closures receive, and what a
/// successful `repo.run(multi)` returns.
public struct MultiValues: Sendable {
    var storage: [String: any Sendable] = [:]

    /// Typed retrieval, no cast at the call site.
    ///
    /// Reading a key whose step hasn't run — ordered after this one, or
    /// never added — throws rather than trapping. It is a wiring bug, and
    /// it is deterministic on first execution, but a step closure runs
    /// inside a transaction on a live server: the right blast radius for
    /// a mistake there is one rolled-back transaction reported through
    /// `MultiResult.failure`, not an aborted process.
    ///
    /// ```swift
    /// .run { r in try await notify(try r[K.user]) }
    /// ```
    public subscript<T: Sendable>(_ key: MultiKey<T>) -> T {
        get throws {
            guard let raw = storage[key.name] else {
                throw HangarError.multiValueMissing(key: key.name)
            }
            guard let value = raw as? T else {
                throw HangarError.multiValueTypeMismatch(
                    key: key.name, stored: "\(type(of: raw))", requested: "\(T.self)")
            }
            return value
        }
    }
}

/// Which step failed, why, and everything that had completed before it —
/// all of which was rolled back.
public struct MultiFailure: Sendable {
    /// The failed step's name.
    public let key: String
    /// What the step threw.
    public let error: any Error
    /// Every result completed before the failure — all rolled back.
    public let completed: MultiValues
}

/// The outcome of `repo.run(multi)`: results keyed by step, or the first
/// failure. Step failures arrive here, not as thrown errors — the throw
/// path is reserved for the transaction machinery itself.
public enum MultiResult: Sendable {
    case success(MultiValues)
    case failure(MultiFailure)
}

/// An ordered list of named steps that run in one transaction.
///
/// Steps are values: build a Multi conditionally, return it from a
/// function, compose two with ``merging(_:)`` — nothing runs until
/// `repo.run(multi)`. Later steps read earlier results through their
/// typed keys; any failure rolls the whole transaction back.
public struct Multi: Sendable {
    struct Step: Sendable {
        let name: String
        let run: @Sendable (Repo, MultiValues) async throws -> any Sendable
    }

    private(set) var steps: [Step] = []

    /// An empty Multi — add steps with `insert`/`update`/`delete`/`run`.
    public init() {}

    // MARK: Changeset steps

    /// Inserts a changeset; the stored row lands under `key`.
    public func insert<M: Table>(_ key: MultiKey<M>, _ changeset: Changeset<M>) -> Multi {
        adding(key.name) { repo, _ in try await repo.insert(changeset) }
    }

    /// Dependent insert: the changeset is built from earlier results —
    /// `.insert(K.profile) { r in profileChangeset(for: try r[K.user]) }`.
    public func insert<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> Changeset<M>
    ) -> Multi {
        adding(key.name) { repo, values in try await repo.insert(make(values)) }
    }

    /// Dependent update: the changeset is built from earlier results.
    /// Updates from a changeset; the stored row lands under `key`.
    public func update<M: Table>(_ key: MultiKey<M>, _ changeset: Changeset<M>) -> Multi {
        adding(key.name) { repo, _ in try await repo.update(changeset) }
    }

    /// Dependent update: the changeset is built from earlier results.
    public func update<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> Changeset<M>
    ) -> Multi {
        adding(key.name) { repo, values in try await repo.update(make(values)) }
    }

    /// Dependent delete: the model to delete is chosen from earlier
    /// results, and lands under `key` as it was before deletion.
    public func delete<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> M
    ) -> Multi {
        adding(key.name) { repo, values in
            let model = try make(values)
            try await repo.delete(model)
            return model
        }
    }

    // MARK: Arbitrary steps

    /// A named step with an arbitrary body — its return value lands under
    /// `key`. The body runs inside the Multi's transaction with the
    /// transaction repo bound as `Repo.current`, so `Repo.require` inside
    /// participates in it.
    public func run<T: Sendable>(
        _ key: MultiKey<T>,
        _ body: @escaping @Sendable (MultiValues) async throws -> T
    ) -> Multi {
        adding(key.name) { _, values in try await body(values) }
    }

    /// A keyless side-effect step —
    /// `.run { r in try await sendWelcomeEmail(to: try r[K.user]) }`. Named
    /// internally by position for failure reporting.
    public func run(
        _ body: @escaping @Sendable (MultiValues) async throws -> Void
    ) -> Multi {
        adding("run#\(steps.count)") { _, values in
            try await body(values)
            return ()
        }
    }

    /// Appends another Multi's steps after this one's (: steps are
    /// values, so composition is data manipulation). Name collisions are
    /// caught by `repo.run(multi)`'s duplicate check.
    public func merging(_ other: Multi) -> Multi {
        var next = self
        next.steps.append(contentsOf: other.steps)
        return next
    }

    private func adding(
        _ name: String,
        _ run: @escaping @Sendable (Repo, MultiValues) async throws -> any Sendable
    ) -> Multi {
        var next = self
        next.steps.append(Step(name: name, run: run))
        return next
    }
}

extension Repo {
    /// Runs every step in one transaction. A step failure rolls the whole
    /// transaction back and returns `.failure` naming the step; the throw
    /// path is reserved for the machinery (connection loss, commit
    /// failure, duplicate step names).
    public func run(_ multi: Multi) async throws -> MultiResult {
        var seen = Set<String>()
        for step in multi.steps {
            guard seen.insert(step.name).inserted else {
                throw HangarError.duplicateMultiStep(name: step.name)
            }
        }

        struct StepFailed: Error {
            let failure: MultiFailure
        }

        do {
            let values = try await transaction { tx in
                var values = MultiValues()
                for step in multi.steps {
                    do {
                        // Ambient access for `run` steps: the
                        // transaction repo is the current repo while a
                        // step executes.
                        let result = try await Repo.with(tx) {
                            try await step.run(tx, values)
                        }
                        values.storage[step.name] = result
                    } catch {
                        throw StepFailed(
                            failure: MultiFailure(key: step.name, error: error, completed: values))
                    }
                }
                return values
            }
            return .success(values)
        } catch let stepFailure as StepFailed {
            return .failure(stepFailure.failure)
        }
    }
}
