import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix

enum NativeDatabaseDriver: String, Codable, Sendable {
    case mysql = "MySQL"
    case mariaDB = "MariaDB"
    case postgreSQL = "PostgreSQL"
    case sqlite = "SQLite"

    init(tablePlusValue: String?) {
        switch tablePlusValue?.lowercased() {
        case "mariadb": self = .mariaDB
        case "postgresql", "postgres", "cockroachdb": self = .postgreSQL
        case "sqlite": self = .sqlite
        default: self = .mysql
        }
    }

    var supportsNativeSync: Bool { self == .mysql || self == .mariaDB }
}

struct NativeDatabaseEndpoint: Sendable {
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String
    let driver: NativeDatabaseDriver
    let ssh: SSHConfiguration?

    init(host: String, port: Int, user: String, password: String, database: String,
         driver: NativeDatabaseDriver = .mysql, ssh: SSHConfiguration? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.driver = driver
        self.ssh = ssh
    }
}

protocol NativeDatabaseAdapter: Sendable {
    static var supportedDrivers: Set<NativeDatabaseDriver> { get }
    func listDatabases(for endpoint: NativeDatabaseEndpoint) async throws -> [String]
    func previewStructure(_ request: NativeStructureRequest) async throws -> NativeStructurePlan
    func applyStructure(_ request: NativeStructureRequest, fingerprint: String) async throws -> Int
    func previewData(_ request: NativeStructureRequest) async throws -> NativeDataPlan
    func applyData(_ request: NativeStructureRequest, fingerprint: String) async throws -> (tables: Int, inserted: Int, updated: Int, deleted: Int)
    func dataDetails(_ request: NativeStructureRequest, table: String, kind: String,
                     offset: Int, limit: Int, tableFingerprint: String) async throws -> NativeDataDetails
}

struct NativeDatabaseAdapterRegistry: Sendable {
    private let mysqlMariaDB = NativeMySQLAdapter()

    func adapter(for driver: NativeDatabaseDriver) throws -> any NativeDatabaseAdapter {
        guard NativeMySQLAdapter.supportedDrivers.contains(driver) else {
            throw BridgeError.message(L10n.format("Adapter native untuk %@ belum tersedia.", driver.rawValue))
        }
        return mysqlMariaDB
    }
}

/// Native MySQL/MariaDB transport used by the Swift application.
/// Diff planning remains separate so it can be shared by future adapters.
actor NativeMySQLAdapter {
    static let supportedDrivers: Set<NativeDatabaseDriver> = [.mysql, .mariaDB]
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let logger = Logger(label: "dev.adityadarma.tableplus.dbsync")

    deinit { try? group.syncShutdownGracefully() }

    func listDatabases(for endpoint: NativeDatabaseEndpoint) async throws -> [String] {
        let connection = try await connect(endpoint, database: "")
        defer { _ = connection.close() }
        let rows = try await connection.simpleQuery("SHOW DATABASES").get()
        return rows.compactMap { row in
            guard let definition = row.columnDefinitions.first else { return nil }
            return row.column(definition.name)?.string
        }
    }

    func simpleQuery(_ sql: String, on endpoint: NativeDatabaseEndpoint) async throws -> [[String: String?]] {
        let connection = try await connect(endpoint, database: endpoint.database)
        defer { _ = connection.close() }
        let rows = try await connection.simpleQuery(sql).get()
        return rows.map { row in
            Dictionary(uniqueKeysWithValues: row.columnDefinitions.compactMap { definition in
                guard let value = row.column(definition.name) else { return nil }
                return (definition.name, value.string)
            })
        }
    }

    func primaryKey(for table: String, on endpoint: NativeDatabaseEndpoint) async throws -> [String] {
        let connection = try await connect(endpoint, database: endpoint.database)
        defer { _ = connection.close() }
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(escaped)' AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX"
        let rows = try await connection.simpleQuery(sql).get()
        return rows.compactMap { $0.column("COLUMN_NAME")?.string }
    }

    func tableRows(_ table: String, on endpoint: NativeDatabaseEndpoint, limit: Int = 50_000) async throws -> (columns: [String], rows: [NativeRow]) {
        let connection = try await connect(endpoint, database: endpoint.database)
        defer { _ = connection.close() }
        let sql = "SELECT * FROM \(try quoteIdentifier(table)) LIMIT \(limit + 1)"
        let result = try await connection.simpleQuery(sql).get()
        guard result.count <= limit else {
            throw BridgeError.message(L10n.format("%@: lebih dari %d baris; batasi tabel yang dipilih.", table, limit))
        }
        let columns = result.first?.columnDefinitions.map { $0.name } ?? []
        return (columns, result.map { row in
            NativeRow(values: Dictionary(uniqueKeysWithValues: columns.map { ($0, row.column($0)?.string) }))
        })
    }

    func connect(_ endpoint: NativeDatabaseEndpoint, database: String) async throws -> MySQLConnection {
        let resolved = try await NativeSSHTunnel.shared.resolve(endpoint)
        return try await MySQLConnection.connect(
            to: .makeAddressResolvingHost(resolved.host, port: resolved.port),
            username: endpoint.user,
            database: database,
            password: endpoint.password.isEmpty ? nil : endpoint.password,
            tlsConfiguration: nil,
            logger: logger,
            on: group.next()
        ).get()
    }
}

extension NativeMySQLAdapter: NativeDatabaseAdapter {}
