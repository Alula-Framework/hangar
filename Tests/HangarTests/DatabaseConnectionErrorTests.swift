import Foundation
import Logging
import PostgresNIO
import Testing

@testable import Hangar

@Suite("A failure to reach the database says what happened")
struct DatabaseConnectionErrorTests {
    /// A client pointed at a port nothing listens on.
    private func withRefusingRepo(_ body: (Repo) async throws -> Void) async throws {
        let configuration = PostgresClient.Configuration(
            host: "127.0.0.1", port: 1, username: "nobody", password: nil, database: "none", tls: .disable)
        let client = PostgresClient(configuration: configuration)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await body(Repo(client: client))
            group.cancelAll()
        }
    }

    private func caught(_ body: () async throws -> Void) async -> (any Error)? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    /// PostgresClient keeps redialling until its circuit breaker trips —
    /// about a minute, with no setting to shorten it — so both pool paths
    /// share one wait.
    @Test("a pool that cannot connect fails statements and transactions as DatabaseConnectionError")
    func refusedPool() async throws {
        try await withRefusingRepo { repo in
            async let statement = caught { _ = try await repo.execute("SELECT 1").collect() }
            async let transaction = caught { try await repo.transaction { _ in } }
            for error in await [statement, transaction] {
                let connection = try #require(error as? DatabaseConnectionError, "\(String(describing: error))")
                #expect(connection.kind == .unreachable)
                #expect(connection.isTransient)
                #expect(connection.description.hasPrefix("could not connect to the database: "), "\(connection)")
            }
        }
    }

    @Test("a refused dial names the reason and the address")
    func refusedDial() async throws {
        let error = await caught {
            _ = try await PostgresConnection.connect(
                configuration: .init(
                    host: "127.0.0.1", port: 1, username: "nobody", password: nil, database: nil, tls: .disable),
                id: 1, logger: Logger(label: "test"))
        }
        let connection = try #require(error.flatMap(DatabaseConnectionError.init), "\(String(describing: error))")
        #expect(connection.kind == .unreachable)
        #expect(connection.description == "could not connect to the database: connection refused (127.0.0.1:1)")
    }

    @Test("connection codes map to kinds; statement-level codes do not")
    func kinds() {
        #expect(DatabaseConnectionError.kind(for: .connectionError) == .unreachable)
        #expect(DatabaseConnectionError.kind(for: .serverClosedConnection) == .connectionLost)
        #expect(DatabaseConnectionError.kind(for: .uncleanShutdown) == .connectionLost)
        #expect(DatabaseConnectionError.kind(for: .sslUnsupported) == .tls)
        #expect(DatabaseConnectionError.kind(for: .saslError) == .authentication)
        #expect(DatabaseConnectionError.kind(for: .poolClosed) == .closed)
        #expect(DatabaseConnectionError.kind(for: .tooManyParameters) == nil)
        #expect(DatabaseConnectionError.kind(for: .queryCancelled) == nil)
        #expect(DatabaseConnectionError.kind(for: .messageDecodingFailure) == nil)
        #expect(DatabaseConnectionError(CancellationError()) == nil)
    }

    @Test("PostgresNIO's dial text becomes the reason and the address")
    func readable() {
        let text =
            "Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:1, error: connection reset (error set): Connection refused) (errno: 111))"
        #expect(readableConnectionFailure(text) == "connection refused (127.0.0.1:1)")
        #expect(
            readableConnectionFailure("read(descriptor:pointer:size:): Connection reset by peer) (errno: 104)")
                == "connection reset by peer")
        #expect(readableConnectionFailure("something else") == "something else")
    }

    @Test("transient covers what a later retry can fix, and only that")
    func transient() {
        for (state, expected) in [
            ("40001", true), ("40P01", true), ("55P03", true), ("57014", true), ("53300", true),
            ("57P01", true), ("57P03", true), ("08006", true),
            ("23505", false), ("42703", false), ("28P01", false), ("22003", false),
        ] {
            #expect(DatabaseError.transient(sqlState: state) == expected, "\(state)")
        }
    }

    @Test("only filter errors are the client's input")
    func clientInput() {
        #expect(HangarError.unknownFilterField(table: "t", field: "f").isClientInput)
        #expect(HangarError.invalidFilterValue(table: "t", field: "f").isClientInput)
        #expect(!HangarError.tooManyRows(table: "t").isClientInput)
        #expect(!HangarError.streamLeaseExpired.isClientInput)
    }
}
