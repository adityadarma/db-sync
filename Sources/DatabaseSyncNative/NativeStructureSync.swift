import Foundation
import CryptoKit
import MySQLNIO

struct NativeSyncOptions: Sendable {
    let tables: [String]
    let destructiveSchema: Bool
    let removeExtraForeignKeys: Bool
    let autoHandleForeignKeys: Bool
    let removeExtraTables: Bool
    let removeExtraRows: Bool
}

struct NativeStructureRequest: Sendable {
    let source: NativeDatabaseEndpoint
    let destination: NativeDatabaseEndpoint
    let options: NativeSyncOptions

    init?(dictionary: [String: Any]) {
        guard let source = Self.endpoint(dictionary["source"]),
              let destination = Self.endpoint(dictionary["destination"]),
              let options = dictionary["options"] as? [String: Any] else { return nil }
        self.source = source
        self.destination = destination
        self.options = NativeSyncOptions(
            tables: options["tables"] as? [String] ?? [],
            destructiveSchema: options["destructiveSchema"] as? Bool ?? false,
            removeExtraForeignKeys: options["removeExtraForeignKeys"] as? Bool ?? false,
            autoHandleForeignKeys: options["autoHandleForeignKeys"] as? Bool ?? false,
            removeExtraTables: options["removeExtraTables"] as? Bool ?? false,
            removeExtraRows: options["removeExtraRows"] as? Bool ?? false
        )
    }

    private static func endpoint(_ value: Any?) -> NativeDatabaseEndpoint? {
        guard let item = value as? [String: Any],
              let host = item["host"] as? String, !host.isEmpty,
              let user = item["user"] as? String, !user.isEmpty,
              let database = item["database"] as? String, !database.isEmpty else { return nil }
        let port = item["port"] as? Int ?? 3306
        guard (1...65535).contains(port) else { return nil }
        let ssh: SSHConfiguration?
        if let rawSSH = item["ssh"] as? [String: Any],
           let sshHost = rawSSH["host"] as? String, !sshHost.isEmpty,
           let sshUser = rawSSH["user"] as? String, !sshUser.isEmpty {
            let sshPort = rawSSH["port"] as? Int ?? 22
            guard (1...65535).contains(sshPort) else { return nil }
            ssh = SSHConfiguration(host: sshHost, port: sshPort, user: sshUser,
                                   privateKeyPath: rawSSH["privateKeyPath"] as? String)
        } else { ssh = nil }
        return NativeDatabaseEndpoint(host: host, port: port, user: user,
                                      password: item["password"] as? String ?? "", database: database,
                                      driver: NativeDatabaseDriver(tablePlusValue: item["driver"] as? String), ssh: ssh)
    }
}

struct NativeSchemaStatement: Sendable {
    let table: String
    let statement: String
}

struct NativeStructurePlan: Sendable {
    let schema: [NativeSchemaStatement]
    let blockers: [String]
    let warnings: [String]
    let fingerprint: String

    func dictionary() -> [String: Any] {
        ["drivers": ["source": "MySQL/MariaDB", "destination": "MySQL/MariaDB"],
         "fingerprint": fingerprint,
         "blockers": blockers,
         "warnings": warnings,
         "extraTables": [],
         "schema": schema.map { ["table": $0.table, "statement": $0.statement] },
         "data": []]
    }
}

private struct TableDefinition {
    var columns: [String: String] = [:]
    var indexes: [String: String] = [:]
    var foreignKeys: [String: String] = [:]
    var primary: String?
    var unknown: [String] = []
    var options = ""
}

func quoteIdentifier(_ value: String) throws -> String {
    guard !value.isEmpty, !value.contains("\0") else { throw BridgeError.message("Nama database/tabel tidak valid.") }
    return "`" + value.replacingOccurrences(of: "`", with: "``") + "`"
}

private func normalized(_ value: String?) -> String {
    guard let value else { return "" }
    return value.replacingOccurrences(of: "AUTO_INCREMENT=[0-9]+", with: "AUTO_INCREMENT=…", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func unquotedIdentifier(_ value: String) -> String {
    String(value.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
}

private func identifierAfterBacktick(_ part: String, expression: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
          let range = Range(match.range(at: 1), in: part) else { return nil }
    return unquotedIdentifier(String(part[range]))
}

enum NativeDropOperation: Equatable {
    case index(table: String, name: String)
    case foreignKey(table: String, name: String)
}

func dropOperation(in statement: String) -> NativeDropOperation? {
    let pattern = #"^\s*ALTER\s+TABLE\s+(`(?:``|[^`])+`)\s+DROP\s+(INDEX|FOREIGN\s+KEY)\s+(`(?:``|[^`])+`)\s*;?\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: statement, range: NSRange(statement.startIndex..., in: statement)),
          let tableRange = Range(match.range(at: 1), in: statement),
          let kindRange = Range(match.range(at: 2), in: statement),
          let nameRange = Range(match.range(at: 3), in: statement) else { return nil }
    let table = unquotedIdentifier(String(statement[tableRange]))
    let name = unquotedIdentifier(String(statement[nameRange]))
    let kind = statement[kindRange].uppercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return kind == "INDEX" ? .index(table: table, name: name) : .foreignKey(table: table, name: name)
}

private func splitDefinitions(_ ddl: String) throws -> ([String], String) {
    guard let open = ddl.firstIndex(of: "(") else { throw BridgeError.message("Format CREATE TABLE tidak dikenal.") }
    var parts: [String] = [], quote: Character?, depth = 0, start = ddl.index(after: open)
    var index = start
    while index < ddl.endIndex {
        let character = ddl[index]
        if let activeQuote = quote {
            if character == activeQuote { quote = nil }
            index = ddl.index(after: index)
            continue
        }
        if character == "'" || character == "\"" || character == "`" { quote = character }
        else if character == "(" { depth += 1 }
        else if character == ")" {
            if depth == 0 {
                parts.append(String(ddl[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                return (parts, String(ddl[ddl.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            depth -= 1
        } else if character == "," && depth == 0 {
            parts.append(String(ddl[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = ddl.index(after: index)
        }
        index = ddl.index(after: index)
    }
    throw BridgeError.message("Format CREATE TABLE tidak lengkap.")
}

/// Creates the tables in a circular dependency before adding their constraints.
/// MySQL requires a referenced table to exist before its foreign key is created.
func createTableStatements(table: String, ddl: String, deferForeignKeys: Bool) throws -> [String] {
    guard deferForeignKeys else { return [ddl] }
    guard let open = ddl.firstIndex(of: "(") else { throw BridgeError.message("Format CREATE TABLE tidak dikenal.") }
    let (definitions, options) = try splitDefinitions(ddl)
    let foreignKeyPattern = #"^(?:CONSTRAINT\s+`(?:``|[^`])+`\s+)?FOREIGN\s+KEY\b"#
    let foreignKeys = definitions.filter {
        $0.range(of: foreignKeyPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    guard !foreignKeys.isEmpty else { return [ddl] }

    let tableDefinition = String(ddl[..<open]) + "(\n  " +
        definitions.filter { definition in !foreignKeys.contains(definition) }.joined(separator: ",\n  ") +
        "\n) " + options
    let quotedTable = try quoteIdentifier(table)
    return [tableDefinition] + foreignKeys.map { "ALTER TABLE \(quotedTable) ADD \($0)" }
}

private func definitionMap(_ ddl: String) throws -> TableDefinition {
    let (parts, options) = try splitDefinitions(ddl)
    var result = TableDefinition(options: options)
    for part in parts {
        if let name = identifierAfterBacktick(part, expression: "^(`(?:``|[^`])+`)\\s+") { result.columns[name] = part }
        else if part.range(of: "^PRIMARY KEY\\b", options: [.regularExpression, .caseInsensitive]) != nil { result.primary = part }
        else if let name = identifierAfterBacktick(part, expression: "^(?:(?:UNIQUE|FULLTEXT|SPATIAL)\\s+)?KEY\\s+(`(?:``|[^`])+`)") { result.indexes[name] = part }
        else if let name = identifierAfterBacktick(part, expression: "^CONSTRAINT\\s+(`(?:``|[^`])+`)\\s+FOREIGN KEY\\b") { result.foreignKeys[name] = part }
        else { result.unknown.append(part) }
    }
    return result
}

func hasUnsupportedDataColumns(_ ddl: String) throws -> Bool {
    try definitionMap(ddl).columns.values.contains {
        $0.range(of: "\\bGENERATED\\s+ALWAYS\\b|\\bINVISIBLE\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private func indexColumns(_ definition: String) -> [String]? {
    guard let open = definition.firstIndex(of: "("), let close = definition[open...].firstIndex(of: ")") else { return nil }
    let body = String(definition[definition.index(after: open)..<close])
    let regex = try? NSRegularExpression(pattern: "`((?:``|[^`])+)`")
    return regex?.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: body) else { return nil }
        return body[range].replacingOccurrences(of: "``", with: "`")
    }
}

private func cleanOptions(_ options: String) -> String {
    normalized(options).replacingOccurrences(of: "AUTO_INCREMENT=…", with: "")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func structureDiff(table: String, sourceDdl: String, targetDdl: String?, options: NativeSyncOptions) throws -> (statements: [String], blockers: [String], changes: [String]) {
    guard let targetDdl else { return ([sourceDdl], [], ["Buat tabel"]) }
    let source = try definitionMap(sourceDdl), target = try definitionMap(targetDdl)
    let quotedTable = try quoteIdentifier(table)
    var beforeChanges: [String] = [], statements: [String] = [], afterChanges: [String] = []
    var blockers: [String] = [], changes: [String] = []
    if normalized(source.primary) != normalized(target.primary) { blockers.append(L10n.format("Primary key berbeda pada %@.", table)) }
    if source.unknown.map(normalized) != target.unknown.map(normalized) { blockers.append(L10n.format("CHECK/constraint lain berbeda pada %@.", table)) }
    if cleanOptions(source.options) != cleanOptions(target.options) { blockers.append(L10n.format("Opsi tabel berbeda pada %@ (ENGINE/charset/collation).", table)) }

    let changedColumns = source.columns.filter { name, definition in
        normalized(definition) != normalized(target.columns[name])
    }
    let removedColumns = target.columns.keys.filter { source.columns[$0] == nil }
    let removedIndexes = target.indexes.filter { name, definition in
        normalized(definition) != normalized(source.indexes[name])
    }
    let addedIndexes = source.indexes.filter { name, definition in
        normalized(definition) != normalized(target.indexes[name])
    }
    let foreignKeysDiffer = Set(source.foreignKeys.keys).union(target.foreignKeys.keys).contains { name in
        normalized(source.foreignKeys[name]) != normalized(target.foreignKeys[name])
    }
    let hasForeignKeys = !source.foreignKeys.isEmpty || !target.foreignKeys.isEmpty
    let extraForeignKeys = target.foreignKeys.keys.filter { source.foreignKeys[$0] == nil }
    let hasSchemaChange = !changedColumns.isEmpty || !removedColumns.isEmpty ||
        !removedIndexes.isEmpty || !addedIndexes.isEmpty || foreignKeysDiffer
    let canRebuildForeignKeys = options.autoHandleForeignKeys && hasForeignKeys && hasSchemaChange &&
        (extraForeignKeys.isEmpty || options.removeExtraForeignKeys)

    if !extraForeignKeys.isEmpty && !options.removeExtraForeignKeys {
        for name in extraForeignKeys.sorted() {
            blockers.append(L10n.format("Foreign key tambahan pada tujuan: %@.%@. Aktifkan opsi hapus foreign key tambahan untuk menghapusnya.", table, name))
        }
    }

    if canRebuildForeignKeys {
        for name in target.foreignKeys.keys.sorted() {
            beforeChanges.append("ALTER TABLE \(quotedTable) DROP FOREIGN KEY \(try quoteIdentifier(name))")
        }
        for name in source.foreignKeys.keys.sorted() {
            guard let definition = source.foreignKeys[name] else { continue }
            afterChanges.append("ALTER TABLE \(quotedTable) ADD \(definition)")
        }
        changes.append("Tangani foreign key")
    } else if foreignKeysDiffer {
        for name in source.foreignKeys.keys.sorted() where normalized(source.foreignKeys[name]) != normalized(target.foreignKeys[name]) {
            blockers.append(L10n.format("Foreign key berbeda pada %@: %@.", table, name))
        }
        if options.removeExtraForeignKeys {
            for name in extraForeignKeys.sorted() {
                statements.append("ALTER TABLE \(quotedTable) DROP FOREIGN KEY \(try quoteIdentifier(name))")
                changes.append("Hapus foreign key \(name)")
            }
        }
    } else if options.removeExtraForeignKeys {
        for name in extraForeignKeys.sorted() {
            statements.append("ALTER TABLE \(quotedTable) DROP FOREIGN KEY \(try quoteIdentifier(name))")
            changes.append("Hapus foreign key \(name)")
        }
    }

    for (name, definition) in changedColumns.sorted(by: { $0.key < $1.key }) {
        let old = target.columns[name]
        if hasForeignKeys && !canRebuildForeignKeys {
            blockers.append(L10n.format("Perubahan kolom pada tabel dengan foreign key perlu penanganan manual: %@.%@.", table, name))
        } else {
            statements.append("ALTER TABLE \(quotedTable) \(old == nil ? "ADD" : "MODIFY") COLUMN \(definition)")
            changes.append("\(old == nil ? "Tambah" : "Ubah") kolom \(name)")
        }
    }
    for name in removedColumns.sorted() {
        if hasForeignKeys && !canRebuildForeignKeys {
            blockers.append(L10n.format("Kolom tambahan pada tabel dengan foreign key perlu penanganan manual: %@.%@.", table, name))
        } else if !options.destructiveSchema {
            blockers.append(L10n.format("Kolom tambahan pada tujuan: %@.%@. Aktifkan opsi hapus kolom dan indeks tambahan untuk menghapusnya.", table, name))
        } else {
            statements.append("ALTER TABLE \(quotedTable) DROP COLUMN \(try quoteIdentifier(name))")
            changes.append("Hapus kolom \(name)")
        }
    }
    for (name, _) in removedIndexes.sorted(by: { $0.key < $1.key }) {
        if hasForeignKeys && !canRebuildForeignKeys {
            blockers.append(L10n.format("Perubahan indeks pada tabel dengan foreign key perlu penanganan manual: %@.%@.", table, name))
        } else if !options.destructiveSchema && source.indexes[name] == nil {
            blockers.append(L10n.format("Indeks tambahan pada tujuan: %@.%@. Aktifkan opsi hapus kolom dan indeks tambahan untuk menghapusnya.", table, name))
        } else {
            statements.append("ALTER TABLE \(quotedTable) DROP INDEX \(try quoteIdentifier(name))")
            changes.append("Hapus indeks \(name)")
        }
    }
    for (name, definition) in addedIndexes.sorted(by: { $0.key < $1.key }) {
        if hasForeignKeys && !canRebuildForeignKeys {
            blockers.append(L10n.format("Perubahan indeks pada tabel dengan foreign key perlu penanganan manual: %@.%@.", table, name))
        } else {
            statements.append("ALTER TABLE \(quotedTable) ADD \(definition)")
            changes.append("Tambah indeks \(name)")
        }
    }
    return (beforeChanges + statements + afterChanges, blockers, changes)
}

extension NativeMySQLAdapter {
    func previewStructure(_ request: NativeStructureRequest) async throws -> NativeStructurePlan {
        guard request.source.driver == request.destination.driver else {
            throw BridgeError.message(L10n.format("Driver sumber (%@) dan tujuan (%@) harus sama.", request.source.driver.rawValue, request.destination.driver.rawValue))
        }
        guard request.source.driver.supportsNativeSync else {
            throw BridgeError.message(L10n.format("Adapter native untuk %@ belum tersedia.", request.source.driver.rawValue))
        }
        guard !(request.source.host == request.destination.host && request.source.port == request.destination.port && request.source.database == request.destination.database) else {
            throw BridgeError.message("Sumber dan tujuan tampak sama. Gunakan database tujuan yang berbeda.")
        }
        let source = try await connect(request.source, database: request.source.database)
        let destination = try await connect(request.destination, database: request.destination.database)
        defer { _ = source.close(); _ = destination.close() }
        let sourceTables = try await tableNames(source)
        let targetTables = try await tableNames(destination)
        let wanted = request.options.tables.isEmpty ? sourceTables : Array(Set(request.options.tables)).sorted()
        for table in wanted where !sourceTables.contains(table) { throw BridgeError.message(L10n.format("Tabel tidak ada pada sumber: %@", table)) }
        var parents: [String: [String]] = [:]
        for table in wanted { parents[table] = try await parentTables(source, table: table) }
        let circularTables = circularForeignKeyTables(wanted, parents: parents)
        let ordered = orderTablesAllowingCircularRelationships(wanted, parents: parents)
        var statements: [NativeSchemaStatement] = [], blockers: [String] = [], warnings: [String] = []
        for table in ordered {
            for parent in parents[table] ?? [] where !ordered.contains(parent) && !targetTables.contains(parent) {
                blockers.append(L10n.format("%@: tabel induk %@ tidak dipilih dan belum ada di tujuan.", table, parent))
            }
            let sourceDdl = try await createTable(source, table: table)
            let targetDdl = targetTables.contains(table) ? try await createTable(destination, table: table) : nil
            let diff = try structureDiff(table: table, sourceDdl: sourceDdl, targetDdl: targetDdl, options: request.options)
            if targetDdl == nil, circularTables.contains(table) {
                statements += try createTableStatements(table: table, ddl: sourceDdl, deferForeignKeys: true)
                    .map { NativeSchemaStatement(table: table, statement: $0) }
            } else {
                statements += diff.statements.map { NativeSchemaStatement(table: table, statement: $0) }
            }
            blockers += diff.blockers
        }
        if request.options.tables.isEmpty {
            let extras = targetTables.filter { !sourceTables.contains($0) }
            if !extras.isEmpty && !request.options.removeExtraTables { warnings.append(L10n.format("Tabel tambahan di tujuan tidak dihapus: %@.", extras.joined(separator: ", "))) }
            if request.options.removeExtraTables {
                var targetParents: [String: [String]] = [:]
                for table in targetTables { targetParents[table] = try await parentTables(destination, table: table) }
                for table in sourceTables {
                    for parent in targetParents[table] ?? [] where extras.contains(parent) {
                        blockers.append(L10n.format("Tabel %@ di tujuan masih bergantung pada tabel tambahan %@.", table, parent))
                    }
                }
                let circularExtras = circularForeignKeyTables(extras, parents: targetParents)
                let reverseOrder = orderTablesAllowingCircularRelationships(targetTables, parents: targetParents).reversed()
                if !circularExtras.isEmpty {
                    statements.append(NativeSchemaStatement(table: "", statement: "SET FOREIGN_KEY_CHECKS = 0"))
                    warnings.append(L10n.format("Tabel tambahan dengan relasi foreign key melingkar akan dihapus dengan pemeriksaan foreign key dinonaktifkan sementara: %@.", circularExtras.sorted().joined(separator: ", ")))
                }
                for table in reverseOrder where extras.contains(table) {
                    statements.append(NativeSchemaStatement(table: table, statement: "DROP TABLE \(try quoteIdentifier(table))"))
                }
                if !circularExtras.isEmpty {
                    statements.append(NativeSchemaStatement(table: "", statement: "SET FOREIGN_KEY_CHECKS = 1"))
                }
            }
        }
        for table in ordered where targetTables.contains(table) {
            let sourceDDL = try await createTable(source, table: table)
            let targetDDL = try await createTable(destination, table: table)
            let diff = try structureDiff(table: table, sourceDdl: sourceDDL, targetDdl: targetDDL, options: request.options)
            let changedColumns = diff.statements.compactMap { sql in
                identifierAfterBacktick(sql, expression: "\\b(?:DROP|MODIFY) COLUMN\\s+(`(?:``|[^`])+`)")
            }
            let droppedIndexes = diff.statements.compactMap { sql in
                identifierAfterBacktick(sql, expression: "\\bDROP INDEX\\s+(`(?:``|[^`])+`)")
            }
            guard !changedColumns.isEmpty || !droppedIndexes.isEmpty else { continue }
            let incoming = try await incomingReferences(destination, table: table)
            for column in changedColumns {
                let references = incoming.filter { $0.column == column }
                if !references.isEmpty {
                    blockers.append(L10n.format("Kolom %@.%@ direferensikan foreign key dari tabel lain: %@.", table, column, references.map(\.reference).joined(separator: ", ")))
                }
            }
            for index in droppedIndexes {
                if incoming.contains(where: { reference in
                    let indexDefinition = (try? definitionMap(targetDDL).indexes[index]) ?? nil
                    guard let indexDefinition, let columns = indexColumns(indexDefinition) else { return true }
                    return columns.contains(reference.column)
                }) {
                    blockers.append(L10n.format("Indeks %@.%@ mungkin dipakai foreign key dari tabel lain dan perlu penanganan manual.", table, index))
                }
            }
        }
        let stable = statements.map {
            "\($0.table.utf8.count):\($0.table)\($0.statement.utf8.count):\($0.statement)"
        }.joined() + blockers.sorted().map { "B\($0.utf8.count):\($0)" }.joined()
        let fingerprint = SHA256.hash(data: Data(stable.utf8)).map { String(format: "%02x", $0) }.joined()
        return NativeStructurePlan(schema: statements, blockers: blockers, warnings: warnings, fingerprint: fingerprint)
    }

    func applyStructure(_ request: NativeStructureRequest, fingerprint: String) async throws -> Int {
        let plan = try await previewStructure(request)
        guard plan.blockers.isEmpty else { throw BridgeError.message(L10n.format("Ada masalah yang harus diselesaikan sebelum sinkronisasi: %@", plan.blockers.joined(separator: " "))) }
        guard plan.fingerprint == fingerprint else { throw BridgeError.message("Database berubah sejak pratinjau. Jalankan pratinjau ulang.") }
        let destination = try await connect(request.destination, database: request.destination.database)
        defer { _ = destination.close() }
        var executed = 0
        var foreignKeyChecksDisabled = false
        do {
            for item in plan.schema {
                if let operation = dropOperation(in: item.statement),
                   try await dropTargetIsMissing(operation, on: destination) {
                    continue
                }
                _ = try await destination.simpleQuery(item.statement).get()
                if item.statement == "SET FOREIGN_KEY_CHECKS = 0" { foreignKeyChecksDisabled = true }
                if item.statement == "SET FOREIGN_KEY_CHECKS = 1" { foreignKeyChecksDisabled = false }
                executed += 1
            }
        } catch {
            if foreignKeyChecksDisabled {
                _ = try? await destination.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
            }
            throw BridgeError.message(L10n.format("Penerapan struktur terhenti setelah %d dari %d perintah: %@", executed, plan.schema.count, error.localizedDescription))
        }
        return executed
    }

    private func dropTargetIsMissing(_ operation: NativeDropOperation, on connection: MySQLConnection) async throws -> Bool {
        let table: String
        let name: String
        switch operation {
        case .index(let targetTable, let targetName):
            table = targetTable
            name = targetName
        case .foreignKey(let targetTable, let targetName):
            table = targetTable
            name = targetName
        }
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let escapedName = name.replacingOccurrences(of: "'", with: "''")
        let query: String
        switch operation {
        case .index:
            query = "SELECT 1 FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(escapedTable)' AND INDEX_NAME = '\(escapedName)' LIMIT 1"
        case .foreignKey:
            query = "SELECT 1 FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = '\(escapedTable)' AND CONSTRAINT_NAME = '\(escapedName)' AND CONSTRAINT_TYPE = 'FOREIGN KEY' LIMIT 1"
        }
        let result = try await connection.simpleQuery(query).get()
        return result.isEmpty
    }

    func tableNames(_ connection: MySQLConnection) async throws -> [String] {
        let rows = try await connection.simpleQuery("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME").get()
        return rows.compactMap { $0.column("TABLE_NAME")?.string }
    }

    func createTable(_ connection: MySQLConnection, table: String) async throws -> String {
        let rows = try await connection.simpleQuery("SHOW CREATE TABLE \(try quoteIdentifier(table))").get()
        guard let row = rows.first else { throw BridgeError.message(L10n.format("Tidak dapat membaca struktur tabel %@.", table)) }
        guard let definition = row.columnDefinitions.first(where: { $0.name.lowercased().contains("create") }),
              let ddl = row.column(definition.name)?.string else {
            throw BridgeError.message(L10n.format("CREATE TABLE tidak tersedia untuk %@.", table))
        }
        return ddl
    }

    func parentTables(_ connection: MySQLConnection, table: String) async throws -> [String] {
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT DISTINCT REFERENCED_TABLE_NAME AS parent FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(escaped)' AND REFERENCED_TABLE_NAME IS NOT NULL"
        let rows = try await connection.simpleQuery(sql).get()
        return rows.compactMap { $0.column("parent")?.string }
    }

    func incomingReferences(_ connection: MySQLConnection, table: String) async throws -> [(column: String, reference: String)] {
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME = '\(escaped)' AND REFERENCED_COLUMN_NAME IS NOT NULL"
        return try await connection.simpleQuery(sql).get().compactMap { row in
            guard let column = row.column("REFERENCED_COLUMN_NAME")?.string,
                  let schema = row.column("TABLE_SCHEMA")?.string,
                  let name = row.column("TABLE_NAME")?.string,
                  let constraint = row.column("CONSTRAINT_NAME")?.string else { return nil }
            return (column, "\(schema).\(name).\(constraint)")
        }
    }

    func orderTables(_ tables: [String], parents: [String: [String]]) throws -> [String] {
        var remaining = Set(tables), result: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { table in (parents[table] ?? []).allSatisfy { !remaining.contains($0) } }.sorted()
            guard !ready.isEmpty else { throw BridgeError.message("Relasi foreign key melingkar; sinkronisasi otomatis belum didukung.") }
            result += ready
            for table in ready { remaining.remove(table) }
        }
        return result
    }

}

/// Structure creation can safely break a dependency cycle by creating all
/// tables first, then adding their foreign keys in a separate statement.
func orderTablesAllowingCircularRelationships(_ tables: [String], parents: [String: [String]]) -> [String] {
    var remaining = Set(tables), result: [String] = []
    while !remaining.isEmpty {
        let ready = remaining.filter {
            (parents[$0] ?? []).allSatisfy { !remaining.contains($0) }
        }.sorted()
        if ready.isEmpty {
            guard let table = remaining.sorted().first else { break }
            result.append(table)
            remaining.remove(table)
        } else {
            result += ready
            for table in ready { remaining.remove(table) }
        }
    }
    return result
}

func circularForeignKeyTables(_ tables: [String], parents: [String: [String]]) -> Set<String> {
    let candidates = Set(tables)
    return Set(tables.filter { table in
        var visited = Set<String>()
        var pending = parents[table, default: []].filter { candidates.contains($0) }
        while let current = pending.popLast() {
            if current == table { return true }
            guard visited.insert(current).inserted else { continue }
            pending += parents[current, default: []].filter { candidates.contains($0) }
        }
        return false
    })
}
