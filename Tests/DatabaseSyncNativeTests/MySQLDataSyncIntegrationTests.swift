import Foundation
import XCTest
@testable import DatabaseSyncNative

final class MySQLDataSyncIntegrationTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    func testPrimaryKeyBatchSyncAcrossMultipleBatches() async throws {
        let source = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_SOURCE_DATABASE")
        let destination = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_DESTINATION_DATABASE")
        let adapter = NativeMySQLAdapter()
        let table = "dbsync_batch_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let quotedTable = try quoteIdentifier(table)

        let sourceConnection = try await adapter.connect(source, database: source.database)
        let destinationConnection = try await adapter.connect(destination, database: destination.database)
        defer { _ = sourceConnection.close(); _ = destinationConnection.close() }

        let create = "CREATE TABLE \(quotedTable) (`id` INT NOT NULL, `name` VARCHAR(64) NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB"
        _ = try await sourceConnection.simpleQuery(create).get()
        _ = try await destinationConnection.simpleQuery(create).get()
        do {
            let sourceValues = (1...1_001).map { "(\($0), 'source-\($0)')" }.joined(separator: ", ")
            _ = try await sourceConnection.simpleQuery("INSERT INTO \(quotedTable) (`id`, `name`) VALUES \(sourceValues)").get()
            _ = try await destinationConnection.simpleQuery("INSERT INTO \(quotedTable) (`id`, `name`) VALUES (1, 'stale')").get()

            let request = NativeStructureRequest(
                source: source,
                destination: destination,
                options: NativeSyncOptions(tables: [table], destructiveSchema: false, removeExtraForeignKeys: false,
                                           autoHandleForeignKeys: false, removeExtraTables: false, removeExtraRows: false,
                                           transactionalDataSync: true)
            )
            let preview = try await adapter.previewData(request)
            XCTAssertTrue(preview.blockers.isEmpty)
            XCTAssertEqual(preview.items.count, 1)
            XCTAssertTrue(preview.items[0].usesBatching)

            let result = try await adapter.applyData(request, fingerprint: preview.fingerprint)
            XCTAssertEqual(result.tables, 1)
            XCTAssertEqual(result.inserted, 1_000)
            XCTAssertEqual(result.updated, 1)
            let targetRows = try await destinationConnection.simpleQuery("SELECT COUNT(*) AS `count` FROM \(quotedTable)").get()
            XCTAssertEqual(targetRows.first?.column("count")?.string, "1001")
            let updated = try await destinationConnection.simpleQuery("SELECT `name` FROM \(quotedTable) WHERE `id` = 1").get()
            XCTAssertEqual(updated.first?.column("name")?.string, "source-1")
        } catch {
            _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
            _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
            throw error
        }
        _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
        _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
    }

    func testTransactionalBatchSyncRollsBackEarlierBatchesOnFailure() async throws {
        try await verifyFailure(transactional: true, expectedRowCount: 1, expectedName: "stale")
    }

    func testPerBatchSyncKeepsCompletedBatchesOnFailure() async throws {
        try await verifyFailure(transactional: false, expectedRowCount: 1_000, expectedName: "source-1")
    }

    func testMutualRequiredForeignKeysSyncWithChecksTemporarilyDisabled() async throws {
        let source = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_SOURCE_DATABASE")
        let destination = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_DESTINATION_DATABASE")
        let adapter = NativeMySQLAdapter()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let firstTable = "dbsync_first_\(suffix)"
        let secondTable = "dbsync_second_\(suffix)"
        let first = try quoteIdentifier(firstTable)
        let second = try quoteIdentifier(secondTable)
        let sourceConnection = try await adapter.connect(source, database: source.database)
        let destinationConnection = try await adapter.connect(destination, database: destination.database)
        defer { _ = sourceConnection.close(); _ = destinationConnection.close() }

        for connection in [sourceConnection, destinationConnection] {
            _ = try await connection.simpleQuery("CREATE TABLE \(first) (`id` INT NOT NULL, `second_id` INT NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB").get()
            _ = try await connection.simpleQuery("CREATE TABLE \(second) (`id` INT NOT NULL, `first_id` INT NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB").get()
            _ = try await connection.simpleQuery("ALTER TABLE \(first) ADD CONSTRAINT `fk_first_second_\(suffix)` FOREIGN KEY (`second_id`) REFERENCES \(second) (`id`)").get()
            _ = try await connection.simpleQuery("ALTER TABLE \(second) ADD CONSTRAINT `fk_second_first_\(suffix)` FOREIGN KEY (`first_id`) REFERENCES \(first) (`id`)").get()
        }
        do {
            _ = try await sourceConnection.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
            _ = try await sourceConnection.simpleQuery("INSERT INTO \(first) (`id`, `second_id`) VALUES (1, 1)").get()
            _ = try await sourceConnection.simpleQuery("INSERT INTO \(second) (`id`, `first_id`) VALUES (1, 1)").get()
            _ = try await sourceConnection.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
            let request = NativeStructureRequest(
                source: source, destination: destination,
                options: NativeSyncOptions(tables: [firstTable, secondTable], destructiveSchema: false,
                                           removeExtraForeignKeys: false, autoHandleForeignKeys: false,
                                           removeExtraTables: false, removeExtraRows: false, transactionalDataSync: true)
            )
            let preview = try await adapter.previewData(request)
            XCTAssertTrue(preview.blockers.isEmpty)
            XCTAssertTrue(preview.requiresForeignKeyChecksDisabled)
            let result = try await adapter.applyData(request, fingerprint: preview.fingerprint)
            XCTAssertEqual(result.inserted, 2)
            for table in [first, second] {
                let rows = try await destinationConnection.simpleQuery("SELECT COUNT(*) AS `count` FROM \(table)").get()
                XCTAssertEqual(rows.first?.column("count")?.string, "1")
            }
        } catch {
            _ = try? await sourceConnection.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
            _ = try? await destinationConnection.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
            _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(first)").get()
            _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(second)").get()
            _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(first)").get()
            _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(second)").get()
            throw error
        }
        _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(first)").get()
        _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(second)").get()
        _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(first)").get()
        _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(second)").get()
    }

    private func verifyFailure(transactional: Bool, expectedRowCount: Int, expectedName: String) async throws {
        let source = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_SOURCE_DATABASE")
        let destination = try endpoint(databaseVariable: "DBSYNC_MYSQL_TEST_DESTINATION_DATABASE")
        let adapter = NativeMySQLAdapter()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let table = "dbsync_rollback_\(suffix)"
        let trigger = "dbsync_fail_\(suffix)"
        let quotedTable = try quoteIdentifier(table)
        let quotedTrigger = try quoteIdentifier(trigger)
        let sourceConnection = try await adapter.connect(source, database: source.database)
        let destinationConnection = try await adapter.connect(destination, database: destination.database)
        defer { _ = sourceConnection.close(); _ = destinationConnection.close() }

        let create = "CREATE TABLE \(quotedTable) (`id` INT NOT NULL, `name` VARCHAR(64) NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB"
        _ = try await sourceConnection.simpleQuery(create).get()
        _ = try await destinationConnection.simpleQuery(create).get()
        do {
            let sourceValues = (1...1_001).map { "(\($0), 'source-\($0)')" }.joined(separator: ", ")
            _ = try await sourceConnection.simpleQuery("INSERT INTO \(quotedTable) (`id`, `name`) VALUES \(sourceValues)").get()
            _ = try await destinationConnection.simpleQuery("INSERT INTO \(quotedTable) (`id`, `name`) VALUES (1, 'stale')").get()
            _ = try await destinationConnection.simpleQuery("CREATE TRIGGER \(quotedTrigger) BEFORE INSERT ON \(quotedTable) FOR EACH ROW IF NEW.`id` = 1001 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'test batch failure'; END IF").get()

            let request = NativeStructureRequest(
                source: source,
                destination: destination,
                options: NativeSyncOptions(tables: [table], destructiveSchema: false, removeExtraForeignKeys: false,
                                           autoHandleForeignKeys: false, removeExtraTables: false, removeExtraRows: false,
                                           transactionalDataSync: transactional)
            )
            let preview = try await adapter.previewData(request)
            do {
                _ = try await adapter.applyData(request, fingerprint: preview.fingerprint)
                XCTFail("Sinkronisasi harus gagal pada batch kedua.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("test batch failure"))
            }
            let rows = try await destinationConnection.simpleQuery("SELECT COUNT(*) AS `count` FROM \(quotedTable)").get()
            XCTAssertEqual(rows.first?.column("count")?.string, String(expectedRowCount))
            let first = try await destinationConnection.simpleQuery("SELECT `name` FROM \(quotedTable) WHERE `id` = 1").get()
            XCTAssertEqual(first.first?.column("name")?.string, expectedName)
        } catch {
            _ = try? await destinationConnection.simpleQuery("DROP TRIGGER IF EXISTS \(quotedTrigger)").get()
            _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
            _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
            throw error
        }
        _ = try? await destinationConnection.simpleQuery("DROP TRIGGER IF EXISTS \(quotedTrigger)").get()
        _ = try? await sourceConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
        _ = try? await destinationConnection.simpleQuery("DROP TABLE IF EXISTS \(quotedTable)").get()
    }

    private func endpoint(databaseVariable: String) throws -> NativeDatabaseEndpoint {
        guard let host = environment["DBSYNC_MYSQL_TEST_HOST"],
              let user = environment["DBSYNC_MYSQL_TEST_USER"],
              let database = environment[databaseVariable] else {
            throw XCTSkip("Set DBSYNC_MYSQL_TEST_HOST, DBSYNC_MYSQL_TEST_USER, DBSYNC_MYSQL_TEST_SOURCE_DATABASE, and DBSYNC_MYSQL_TEST_DESTINATION_DATABASE to run MySQL integration tests.")
        }
        let port = Int(environment["DBSYNC_MYSQL_TEST_PORT"] ?? "3306") ?? 3306
        return NativeDatabaseEndpoint(host: host, port: port, user: user,
                                     password: environment["DBSYNC_MYSQL_TEST_PASSWORD"] ?? "",
                                     database: database, driver: .mysql)
    }
}
