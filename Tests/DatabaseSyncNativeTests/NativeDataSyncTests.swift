import XCTest
@testable import DatabaseSyncNative

final class NativeDataSyncTests: XCTestCase {
    private func row(_ id: String?, _ name: String? = nil) -> NativeRow {
        NativeRow(values: ["id": id, "name": name])
    }

    func testDiffCreatesInsertsUpdatesAndDeletesByPrimaryKey() throws {
        let diff = try nativeDiffRows(
            source: [row("1", "new"), row("2", "added")],
            target: [row("1", "old"), row("3", "removed")],
            columns: ["id", "name"], keyColumns: ["id"], removeExtraRows: true
        )

        XCTAssertEqual(diff.inserts, [row("2", "added")])
        XCTAssertEqual(diff.updates.map(\.before), [row("1", "old")])
        XCTAssertEqual(diff.updates.map(\.after), [row("1", "new")])
        XCTAssertEqual(diff.deletes, [row("3", "removed")])
        XCTAssertEqual(diff.extraRows, [row("3", "removed")])
    }

    func testDiffKeepsExtraRowsWhenRemovalDisabled() throws {
        let diff = try nativeDiffRows(source: [row("1", "same")], target: [row("1", "same"), row("2", "extra")],
                                      columns: ["id", "name"], keyColumns: ["id"], removeExtraRows: false)

        XCTAssertTrue(diff.inserts.isEmpty)
        XCTAssertTrue(diff.updates.isEmpty)
        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertEqual(diff.extraRows, [row("2", "extra")])
    }

    func testDiffRejectsDuplicatePrimaryKeys() {
        XCTAssertThrowsError(try nativeDiffRows(source: [row("1"), row("1")], target: [],
                                                columns: ["id", "name"], keyColumns: ["id"], removeExtraRows: false))
    }

    func testDiffWithoutKeyPreservesDuplicateRows() throws {
        let source = [row("1", "same"), row("1", "same"), row("2", "new")]
        let target = [row("1", "same"), row("3", "extra")]
        let diff = try nativeDiffRows(source: source, target: target, columns: ["id", "name"],
                                      keyColumns: [], removeExtraRows: true)

        XCTAssertEqual(diff.inserts, [row("1", "same"), row("2", "new")])
        XCTAssertEqual(diff.deletes, [row("3", "extra")])
    }

    func testBatchSourceSQLUsesPrimaryKeyCursor() throws {
        XCTAssertEqual(
            try nativeBatchSourceSQL(table: "assets", columns: ["id", "name"], keyColumns: ["id"], hasCursor: true),
            "SELECT `id`, `name` FROM `assets` WHERE (`id`) > (?) ORDER BY `id` LIMIT 1000"
        )
    }

    func testFirstBatchSQLHasNoCursorPredicate() throws {
        XCTAssertEqual(
            try nativeBatchSourceSQL(table: "assets", columns: ["id"], keyColumns: ["id"], hasCursor: false),
            "SELECT `id` FROM `assets` ORDER BY `id` LIMIT 1000"
        )
    }

    func testBatchSourceSQLSupportsCompositePrimaryKey() throws {
        XCTAssertEqual(
            try nativeBatchSourceSQL(table: "lines", columns: ["order_id", "line_id"],
                                     keyColumns: ["order_id", "line_id"], hasCursor: true),
            "SELECT `order_id`, `line_id` FROM `lines` WHERE (`order_id`, `line_id`) > (?, ?) ORDER BY `order_id`, `line_id` LIMIT 1000"
        )
    }

    func testBatchTargetSQLMatchesOnlyBatchKeys() throws {
        XCTAssertEqual(
            try nativeBatchTargetSQL(table: "assets", columns: ["id", "name"], keyColumns: ["id"], rowCount: 2),
            "SELECT `id`, `name` FROM `assets` WHERE (`id` <=> ?) OR (`id` <=> ?)"
        )
    }

    func testBatchTargetSQLSupportsCompositePrimaryKey() throws {
        XCTAssertEqual(
            try nativeBatchTargetSQL(table: "lines", columns: ["order_id", "line_id"],
                                     keyColumns: ["order_id", "line_id"], rowCount: 2),
            "SELECT `order_id`, `line_id` FROM `lines` WHERE (`order_id` <=> ? AND `line_id` <=> ?) OR (`order_id` <=> ? AND `line_id` <=> ?)"
        )
    }

    func testRequestDefaultsToTransactionalDataSync() {
        let request = NativeStructureRequest(dictionary: [
            "source": ["host": "source", "user": "root", "database": "source", "driver": "MySQL"],
            "destination": ["host": "destination", "user": "root", "database": "destination", "driver": "MySQL"],
            "options": [:]
        ])

        XCTAssertTrue(request?.options.transactionalDataSync ?? false)
    }

    func testRequestAllowsPerBatchTransactions() {
        let request = NativeStructureRequest(dictionary: [
            "source": ["host": "source", "user": "root", "database": "source", "driver": "MySQL"],
            "destination": ["host": "destination", "user": "root", "database": "destination", "driver": "MySQL"],
            "options": ["transactionalDataSync": false]
        ])

        XCTAssertFalse(request?.options.transactionalDataSync ?? true)
    }
}
