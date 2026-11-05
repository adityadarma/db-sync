import XCTest
@testable import DatabaseSyncNative

final class NativeStructureSyncTests: XCTestCase {
    private let source = """
    CREATE TABLE `orders` (
      `id` bigint NOT NULL,
      `customer_id` bigint NOT NULL,
      KEY `orders_customer_id_index` (`customer_id`),
      CONSTRAINT `orders_customer_id_foreign` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`)
    ) ENGINE=InnoDB
    """

    private let target = """
    CREATE TABLE `orders` (
      `id` bigint NOT NULL,
      `customer_id` bigint NOT NULL,
      KEY `orders_customer_id_index` (`customer_id`, `id`),
      CONSTRAINT `orders_customer_id_foreign` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`)
    ) ENGINE=InnoDB
    """

    func testForeignKeyIndexChangeIsBlockedWithoutAutomaticHandling() throws {
        let plan = try structureDiff(table: "orders", sourceDdl: source, targetDdl: target,
                                     options: options(autoHandleForeignKeys: false))

        XCTAssertTrue(plan.statements.isEmpty)
        XCTAssertEqual(plan.blockers.count, 2)
        XCTAssertTrue(plan.blockers.allSatisfy { $0.contains("orders_customer_id_index") })
    }

    func testAutomaticHandlingDropsAndRecreatesForeignKeyAroundIndexChange() throws {
        let plan = try structureDiff(table: "orders", sourceDdl: source, targetDdl: target,
                                     options: options(autoHandleForeignKeys: true))

        XCTAssertTrue(plan.blockers.isEmpty)
        XCTAssertEqual(plan.statements.count, 4)
        XCTAssertTrue(plan.statements[0].contains("DROP FOREIGN KEY `orders_customer_id_foreign`"))
        XCTAssertTrue(plan.statements[1].contains("DROP INDEX `orders_customer_id_index`"))
        XCTAssertTrue(plan.statements[2].contains("ADD KEY `orders_customer_id_index`"))
        XCTAssertTrue(plan.statements[3].contains("ADD CONSTRAINT `orders_customer_id_foreign`"))
    }

    func testParsesDropsSoMissingObjectsCanBeSkippedDuringApply() {
        XCTAssertEqual(
            dropOperation(in: "ALTER TABLE `customers` DROP INDEX `customers_branch_id_foreign`"),
            .index(table: "customers", name: "customers_branch_id_foreign")
        )
        XCTAssertEqual(
            dropOperation(in: "ALTER TABLE `customers` DROP FOREIGN KEY `customers_branch_id_foreign`"),
            .foreignKey(table: "customers", name: "customers_branch_id_foreign")
        )
    }

    func testCanonicalColumnsIgnorePhysicalColumnOrder() {
        XCTAssertEqual(
            canonicalColumns(source: ["id", "name", "updated_at"], destination: ["updated_at", "id", "name"]),
            ["id", "name", "updated_at"]
        )
        XCTAssertNil(canonicalColumns(source: ["id", "name"], destination: ["id", "email"]))
    }

    func testCircularForeignKeyTableCreationDefersConstraintUntilTableExists() throws {
        let ddl = """
        CREATE TABLE `employees` (
          `id` bigint NOT NULL,
          `manager_id` bigint DEFAULT NULL,
          PRIMARY KEY (`id`),
          CONSTRAINT `employees_manager_foreign` FOREIGN KEY (`manager_id`) REFERENCES `employees` (`id`)
        ) ENGINE=InnoDB
        """

        let statements = try createTableStatements(table: "employees", ddl: ddl, deferForeignKeys: true)

        XCTAssertEqual(statements.count, 2)
        XCTAssertFalse(statements[0].contains("FOREIGN KEY"))
        XCTAssertEqual(statements[1], "ALTER TABLE `employees` ADD CONSTRAINT `employees_manager_foreign` FOREIGN KEY (`manager_id`) REFERENCES `employees` (`id`)")
    }

    func testCircularTablesAreIdentifiedForSafeRemoval() {
        let parents = ["a": ["b"], "b": ["a"], "audit": ["a"]]

        XCTAssertEqual(circularForeignKeyTables(["a", "b", "audit"], parents: parents), ["a", "b"])
        XCTAssertEqual(orderTablesAllowingCircularRelationships(["a", "b", "audit"], parents: parents), ["a", "audit", "b"])
    }

    func testPasswordKeySurvivesTablePlusConnectionIDChanges() {
        let first = Profile(id: "tp-original", name: "Local", host: "127.0.0.1", port: 3306,
                            user: "root", database: "app", isTablePlus: true, driver: "MySQL")
        let restored = Profile(id: "tp-restored", name: "Copied connection", host: "127.0.0.1", port: 3306,
                               user: "ROOT", database: "other_app", isTablePlus: true, driver: "MySQL")

        XCTAssertEqual(first.passwordKey, restored.passwordKey)
    }

    private func options(autoHandleForeignKeys: Bool) -> NativeSyncOptions {
        NativeSyncOptions(tables: [], destructiveSchema: false, removeExtraForeignKeys: false,
                          autoHandleForeignKeys: autoHandleForeignKeys, removeExtraTables: false,
                          removeExtraRows: false)
    }
}
