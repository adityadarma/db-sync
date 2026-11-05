import Foundation
import CryptoKit
import MySQLNIO

private let snapshotRowLimit = 50_000
private let batchRowLimit = 1_000

/// Snapshot data yang dipakai engine native sebelum transaksi apply dimulai.
/// Nilai disimpan sebagai string/NULL karena MySQLNIO mengirim hasil SELECT dalam bentuk teks.
struct NativeRow: Sendable, Hashable, Codable {
    let values: [String: String?]
}

struct NativeDataDiff: Sendable {
    let inserts: [NativeRow]
    let updates: [(before: NativeRow, after: NativeRow)]
    let deletes: [NativeRow]
    let extraRows: [NativeRow]
}

private func nativeRowKey(_ row: NativeRow, columns: [String]) -> String {
    columns.map { column -> String in
        let value = row.values[column] ?? nil
        guard let value else { return "N;" }
        return "S\(value.utf8.count):\(value);"
    }.joined()
}

private func nativeRowsEqual(_ lhs: NativeRow, _ rhs: NativeRow, columns: [String]) -> Bool {
    columns.allSatisfy { lhs.values[$0] ?? nil == rhs.values[$0] ?? nil }
}

func nativeBatchSourceSQL(table: String, columns: [String], keyColumns: [String], hasCursor: Bool) throws -> String {
    let quotedTable = try quoteIdentifier(table)
    let quotedColumns = try columns.map(quoteIdentifier).joined(separator: ", ")
    let quotedKeys = try keyColumns.map(quoteIdentifier).joined(separator: ", ")
    let predicate = hasCursor
        ? " WHERE (\(quotedKeys)) > (\(Array(repeating: "?", count: keyColumns.count).joined(separator: ", ")))"
        : ""
    return "SELECT \(quotedColumns) FROM \(quotedTable)\(predicate) ORDER BY \(quotedKeys) LIMIT \(batchRowLimit)"
}

func nativeBatchTargetSQL(table: String, columns: [String], keyColumns: [String], rowCount: Int) throws -> String {
    let quotedTable = try quoteIdentifier(table)
    let quotedColumns = try columns.map(quoteIdentifier).joined(separator: ", ")
    let keyPredicate = try keyColumns.map { "\(try quoteIdentifier($0)) <=> ?" }.joined(separator: " AND ")
    let predicate = Array(repeating: "(\(keyPredicate))", count: rowCount).joined(separator: " OR ")
    return "SELECT \(quotedColumns) FROM \(quotedTable) WHERE \(predicate)"
}

/// Urutan fisik kolom tidak mengubah makna sebuah baris. Data dibandingkan dan
/// ditulis menggunakan urutan nama yang stabil agar SELECT * dari dua database
/// dengan urutan kolom berbeda tetap dapat disinkronkan.
func canonicalColumns(source: [String], destination: [String]) -> [String]? {
    let sourceNames = Set(source), destinationNames = Set(destination)
    guard source.count == sourceNames.count,
          destination.count == destinationNames.count,
          sourceNames == destinationNames else { return nil }
    return sourceNames.sorted()
}

/// Membuat rencana perubahan tanpa menulis apa pun ke database tujuan.
/// Untuk tabel pivot tanpa primary/unique key, setiap baris sumber hanya dapat
/// mencocokkan satu baris tujuan yang identik.
func nativeDiffRows(source: [NativeRow], target: [NativeRow], columns: [String],
                    keyColumns: [String], removeExtraRows: Bool) throws -> NativeDataDiff {
    if keyColumns.isEmpty {
        var remaining = target
        var inserts: [NativeRow] = []
        for row in source {
            if let index = remaining.firstIndex(where: { nativeRowsEqual($0, row, columns: columns) }) {
                remaining.remove(at: index)
            } else {
                inserts.append(row)
            }
        }
        return NativeDataDiff(inserts: inserts, updates: [],
                              deletes: removeExtraRows ? remaining : [], extraRows: remaining)
    }

    var sourceByKey: [String: NativeRow] = [:], targetByKey: [String: NativeRow] = [:]
    for row in source {
        let key = nativeRowKey(row, columns: keyColumns)
        guard sourceByKey[key] == nil else { throw BridgeError.message("Kunci baris duplikat pada sumber.") }
        sourceByKey[key] = row
    }
    for row in target {
        let key = nativeRowKey(row, columns: keyColumns)
        guard targetByKey[key] == nil else { throw BridgeError.message("Kunci baris duplikat pada tujuan.") }
        targetByKey[key] = row
    }
    var inserts: [NativeRow] = [], updates: [(before: NativeRow, after: NativeRow)] = []
    for (key, row) in sourceByKey {
        guard let previous = targetByKey[key] else { inserts.append(row); continue }
        if !nativeRowsEqual(previous, row, columns: columns) { updates.append((before: previous, after: row)) }
    }
    let extras = targetByKey.compactMap { sourceByKey[$0.key] == nil ? $0.value : nil }
    return NativeDataDiff(inserts: inserts, updates: updates,
                          deletes: removeExtraRows ? extras : [], extraRows: extras)
}

func nativeFingerprint(_ parts: [String]) -> String {
    SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
}

struct NativeDataPlanItem: Sendable {
    let table: String
    let columns: [String]
    let keyColumns: [String]
    let sourceDDL: String
    let targetDDL: String
    let diff: NativeDataDiff
    let fingerprint: String
    let usesBatching: Bool
    let sourceRowCount: Int

    func previewDictionary() -> [String: Any] {
        ["table": table, "tableFingerprint": fingerprint,
          "insert": diff.inserts.count, "update": diff.updates.count,
          "delete": diff.deletes.count, "extraRows": diff.extraRows.count,
          "batch": usesBatching, "sourceRowCount": sourceRowCount]
    }
}

struct NativeDataPlan: Sendable {
    let items: [NativeDataPlanItem]
    let blockers: [String]
    let warnings: [String]
    let fingerprint: String
    let requiresForeignKeyChecksDisabled: Bool

    func previewDictionary() -> [String: Any] {
        ["drivers": ["source": "MySQL/MariaDB", "destination": "MySQL/MariaDB"],
         "fingerprint": fingerprint, "blockers": blockers, "warnings": warnings,
         "extraTables": [], "schema": [], "data": items.map { $0.previewDictionary() }]
    }

    func details(table: String, kind: String, offset: Int, limit: Int,
                 expectedFingerprint: String) throws -> NativeDataDetails {
        guard let item = items.first(where: { $0.table == table }), item.fingerprint == expectedFingerprint else {
            throw BridgeError.message("Data tabel berubah sejak pratinjau. Bandingkan ulang untuk melihat rincian terbaru.")
        }
        let totalRows: [(before: NativeRow?, after: NativeRow?)]
        switch kind {
        case "insert": totalRows = item.diff.inserts.map { (nil, $0) }
        case "update": totalRows = item.diff.updates.map { ($0.before, $0.after) }
        case "delete": totalRows = item.diff.deletes.map { ($0, nil) }
        case "extra": totalRows = item.diff.extraRows.map { ($0, nil) }
        default: throw BridgeError.message("Pilihan rincian data tidak valid.")
        }
        guard offset >= 0, limit > 0, limit <= 50 else { throw BridgeError.message("Pilihan halaman rincian tidak valid.") }
        let page = Array(totalRows.dropFirst(offset).prefix(limit)).map { pair -> NativeDataDetailRow in
            let changed = item.columns.filter { column in
                (pair.before?.values[column] ?? nil) != (pair.after?.values[column] ?? nil)
            }
            return NativeDataDetailRow(before: pair.before, after: pair.after, changes: changed)
        }
        return NativeDataDetails(table: table, kind: kind, offset: offset, limit: limit,
                                 total: totalRows.count, columns: item.columns,
                                 keyColumns: item.keyColumns, rows: page)
    }
}

struct NativeDataDetailRow: Sendable {
    let before: NativeRow?
    let after: NativeRow?
    let changes: [String]
}

struct NativeDataDetails: Sendable {
    let table: String
    let kind: String
    let offset: Int
    let limit: Int
    let total: Int
    let columns: [String]
    let keyColumns: [String]
    let rows: [NativeDataDetailRow]

    func dictionary() -> [String: Any] {
        let mapped = rows.map { row -> [String: Any] in
            let before: Any = row.before.map { rowDictionary($0, columns: columns) } ?? (NSNull() as Any)
            let after: Any = row.after.map { rowDictionary($0, columns: columns) } ?? (NSNull() as Any)
            return ["before": before, "after": after, "changes": row.changes]
        }
        return ["table": table, "kind": kind, "offset": offset, "limit": limit,
                "total": total, "columns": columns, "keyColumns": keyColumns, "rows": mapped]
    }
}

private func rowDictionary(_ row: NativeRow, columns: [String]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: columns.map { column in
        let value = row.values[column] ?? nil
        return (column, value as Any? ?? NSNull())
    })
}

private final class NativeAffectedRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    func set(_ value: UInt64) { lock.lock(); stored = value; lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return stored }
}

extension NativeMySQLAdapter {
    func previewData(_ request: NativeStructureRequest) async throws -> NativeDataPlan {
        try validateSameDriver(request)
        let source = try await connect(request.source, database: request.source.database)
        let destination = try await connect(request.destination, database: request.destination.database)
        defer { _ = source.close(); _ = destination.close() }

        let sourceTables = try await tableNames(source), targetTables = try await tableNames(destination)
        let tables = request.options.tables.isEmpty ? sourceTables : Array(Set(request.options.tables)).sorted()
        for table in tables where !sourceTables.contains(table) {
            throw BridgeError.message(L10n.format("Tabel tidak ada pada sumber: %@", table))
        }
        var parents: [String: [String]] = [:]
        for table in tables { parents[table] = try await parentTables(source, table: table) }
        let circularTables = circularForeignKeyTables(tables, parents: parents)
        let ordered = orderTablesAllowingCircularRelationships(tables, parents: parents)
        var blockers: [String] = [], warnings: [String] = [], items: [NativeDataPlanItem] = [], fingerprints: [String] = []
        if !circularTables.isEmpty {
            warnings.append(L10n.format("Data pada tabel dengan relasi foreign key melingkar akan diterapkan dengan pemeriksaan foreign key dinonaktifkan sementara: %@. Ini diperlukan ketika foreign key saling bergantung, termasuk kolom NOT NULL; urutan insert saja tidak dapat memenuhi siklus.", circularTables.sorted().joined(separator: ", ")))
        }

        for table in ordered {
            for parent in parents[table] ?? [] where !ordered.contains(parent) && !targetTables.contains(parent) {
                blockers.append(L10n.format("%@: tabel induk %@ tidak dipilih dan belum ada di tujuan.", table, parent))
            }
            guard targetTables.contains(table) else {
                blockers.append(L10n.format("%@: tabel belum ada pada tujuan. Jalankan sinkronisasi struktur terlebih dahulu.", table))
                continue
            }
            let sourceDDL = try await createTable(source, table: table)
            let targetDDL = try await createTable(destination, table: table)
            let structural = try structureDiff(table: table, sourceDdl: sourceDDL, targetDdl: targetDDL, options: request.options)
            if !structural.statements.isEmpty || !structural.blockers.isEmpty {
                blockers.append(L10n.format("%@: struktur sumber dan tujuan berbeda. Jalankan sinkronisasi struktur terlebih dahulu.", table))
                continue
            }
            if try hasUnsupportedDataColumns(sourceDDL) {
                blockers.append(L10n.format("%@: kolom generated/invisible belum didukung untuk sinkronisasi data.", table))
                continue
            }
            let sourceCount = try await rowCount(source, table: table)
            let targetCount = try await rowCount(destination, table: table)
            let sourceColumns = try await tableColumns(source, table: table)
            let targetColumns = try await tableColumns(destination, table: table)
            guard let columns = canonicalColumns(source: sourceColumns, destination: targetColumns) else {
                let sourceOnly = Set(sourceColumns).subtracting(targetColumns).sorted().joined(separator: ", ")
                let destinationOnly = Set(targetColumns).subtracting(sourceColumns).sorted().joined(separator: ", ")
                blockers.append(L10n.format("%@: daftar kolom sumber dan tujuan berbeda. Hanya di sumber: %@. Hanya di tujuan: %@.",
                                            table, sourceOnly.isEmpty ? "—" : sourceOnly,
                                            destinationOnly.isEmpty ? "—" : destinationOnly))
                continue
            }
            let primary = try await primaryKey(source, table: table)
            if !primary.isEmpty {
                if request.options.removeExtraRows {
                    blockers.append(L10n.format("%@: hapus baris tambahan belum didukung untuk sinkronisasi batch. Nonaktifkan opsi hapus baris tambahan.", table))
                    continue
                }
                let tableFingerprint = nativeFingerprint([table, sourceDDL, targetDDL, "batch", String(sourceCount), String(targetCount)])
                items.append(NativeDataPlanItem(table: table, columns: columns, keyColumns: primary,
                                                sourceDDL: sourceDDL, targetDDL: targetDDL,
                                                diff: NativeDataDiff(inserts: [], updates: [], deletes: [], extraRows: []),
                                                fingerprint: tableFingerprint, usesBatching: true,
                                                sourceRowCount: sourceCount))
                fingerprints.append(table + ":" + tableFingerprint)
                warnings.append(L10n.format("%@: %d baris akan diperiksa per %d baris menggunakan primary key. Pratinjau tidak merinci setiap perubahan.", table, sourceCount, batchRowLimit))
                continue
            }
            if sourceCount > snapshotRowLimit || targetCount > snapshotRowLimit {
                blockers.append(L10n.format("%@: lebih dari %d baris dan tidak memiliki primary key; sinkronisasi batch tidak aman.", table, snapshotRowLimit))
                continue
            }
            let sourceSnapshot = try await rows(source, table: table)
            let targetSnapshot = try await rows(destination, table: table)
            let sourceRows = (columns: columns, rows: sortRows(sourceSnapshot.rows))
            let targetRows = (columns: columns, rows: sortRows(targetSnapshot.rows))
            let unique = primary.isEmpty ? try await uniqueKey(source, table: table, columns: sourceRows.columns,
                                                                sourceRows: sourceRows.rows, targetRows: targetRows.rows) : []
            let keys = primary.isEmpty ? unique : primary
            if primary.isEmpty {
                warnings.append(keys.isEmpty
                    ? L10n.format("%@: tanpa primary key atau indeks unik; baris dicocokkan berdasarkan seluruh kolom. Perubahan nilai dihitung sebagai baris baru.", table)
                    : L10n.format("%@: tanpa primary key; indeks unik (%@) dipakai untuk mencocokkan baris.", table, keys.joined(separator: ", ")))
            }
            let diff = try nativeDiffRows(source: sourceRows.rows, target: targetRows.rows,
                                          columns: sourceRows.columns, keyColumns: keys,
                                          removeExtraRows: request.options.removeExtraRows)
            if !diff.extraRows.isEmpty && !request.options.removeExtraRows {
                warnings.append(L10n.format("%@: %d baris tambahan di tujuan tidak akan dihapus.", table, diff.extraRows.count))
            }
            let tableFingerprint = fingerprint(table: table, sourceDDL: sourceDDL, targetDDL: targetDDL,
                                               sourceRows: sourceRows.rows, targetRows: targetRows.rows)
            items.append(NativeDataPlanItem(table: table, columns: sourceRows.columns, keyColumns: keys,
                                             sourceDDL: sourceDDL, targetDDL: targetDDL,
                                             diff: diff, fingerprint: tableFingerprint, usesBatching: false,
                                             sourceRowCount: sourceRows.rows.count))
            fingerprints.append(table + ":" + tableFingerprint)
        }
        let overall = nativeFingerprint(fingerprints + blockers.sorted())
        return NativeDataPlan(items: items, blockers: blockers, warnings: warnings, fingerprint: overall,
                              requiresForeignKeyChecksDisabled: !circularTables.isEmpty)
    }

    func applyData(_ request: NativeStructureRequest, fingerprint: String) async throws -> (tables: Int, inserted: Int, updated: Int, deleted: Int) {
        let plan = try await previewData(request)
        guard plan.blockers.isEmpty else { throw BridgeError.message(L10n.format("Ada masalah yang harus diselesaikan sebelum sinkronisasi: %@", plan.blockers.joined(separator: " "))) }
        guard plan.fingerprint == fingerprint else { throw BridgeError.message("Database berubah sejak pratinjau. Jalankan pratinjau ulang.") }
        let connection = try await connect(request.destination, database: request.destination.database)
        let source = try await connect(request.source, database: request.source.database)
        defer { _ = connection.close(); _ = source.close() }
        if request.options.transactionalDataSync {
            _ = try await connection.simpleQuery("START TRANSACTION").get()
        }
        var inserted = 0, updated = 0, deleted = 0
        var foreignKeyChecksDisabled = false
        do {
            if plan.requiresForeignKeyChecksDisabled {
                _ = try await connection.simpleQuery("SET FOREIGN_KEY_CHECKS = 0").get()
                foreignKeyChecksDisabled = true
            }
            for item in plan.items {
                if item.usesBatching {
                    let result = try await applyBatches(source: source, destination: connection, item: item,
                                                        transactional: request.options.transactionalDataSync)
                    inserted += result.inserted
                    updated += result.updated
                    continue
                }
                if !request.options.transactionalDataSync {
                    _ = try await connection.simpleQuery("START TRANSACTION").get()
                }
                inserted += try await insertRows(connection, item: item)
                updated += try await updateRows(connection, item: item)
                deleted += try await deleteRows(connection, item: item)
                if !request.options.transactionalDataSync {
                    _ = try await connection.simpleQuery("COMMIT").get()
                }
            }
            if foreignKeyChecksDisabled {
                _ = try await connection.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
                foreignKeyChecksDisabled = false
            }
            if request.options.transactionalDataSync {
                _ = try await connection.simpleQuery("COMMIT").get()
            }
        } catch {
            if foreignKeyChecksDisabled {
                _ = try? await connection.simpleQuery("SET FOREIGN_KEY_CHECKS = 1").get()
            }
            _ = try? await connection.simpleQuery("ROLLBACK").get()
            throw error
        }
        return (plan.items.count, inserted, updated, deleted)
    }

    func dataDetails(_ request: NativeStructureRequest, table: String, kind: String,
                     offset: Int, limit: Int, tableFingerprint: String) async throws -> NativeDataDetails {
        let plan = try await previewData(request)
        return try plan.details(table: table, kind: kind, offset: offset, limit: limit,
                                expectedFingerprint: tableFingerprint)
    }

    private func validateSameDriver(_ request: NativeStructureRequest) throws {
        guard request.source.driver == request.destination.driver else {
            throw BridgeError.message(L10n.format("Driver sumber (%@) dan tujuan (%@) harus sama.", request.source.driver.rawValue, request.destination.driver.rawValue))
        }
        guard request.source.driver.supportsNativeSync else {
            throw BridgeError.message(L10n.format("Adapter native untuk %@ belum tersedia.", request.source.driver.rawValue))
        }
        guard !(request.source.host == request.destination.host && request.source.port == request.destination.port && request.source.database == request.destination.database) else {
            throw BridgeError.message("Sumber dan tujuan tampak sama. Gunakan database tujuan yang berbeda.")
        }
    }

    private func rows(_ connection: MySQLConnection, table: String) async throws -> (columns: [String], rows: [NativeRow]) {
        let sql = "SELECT * FROM \(try quoteIdentifier(table)) LIMIT \(snapshotRowLimit + 1)"
        let result = try await connection.simpleQuery(sql).get()
        guard result.count <= snapshotRowLimit else { throw BridgeError.message(L10n.format("%@: lebih dari %d baris; batasi tabel yang dipilih.", table, snapshotRowLimit)) }
        let columns = try await tableColumns(connection, table: table)
        return (columns, result.map { row in
            NativeRow(values: Dictionary(uniqueKeysWithValues: columns.map { ($0, row.column($0)?.string) }))
        })
    }

    private func rowCount(_ connection: MySQLConnection, table: String) async throws -> Int {
        let result = try await connection.simpleQuery("SELECT COUNT(*) AS `count` FROM \(try quoteIdentifier(table))").get()
        return Int(result.first?.column("count")?.string ?? "") ?? 0
    }

    private func batchRows(_ connection: MySQLConnection, item: NativeDataPlanItem,
                           after cursor: NativeRow?) async throws -> [NativeRow] {
        let cursorValues = cursor.map { binds($0, columns: item.keyColumns) } ?? []
        let sql = try nativeBatchSourceSQL(table: item.table, columns: item.columns,
                                           keyColumns: item.keyColumns, hasCursor: cursor != nil)
        let result = try await connection.query(sql, cursorValues).get()
        return result.map { row in
            NativeRow(values: Dictionary(uniqueKeysWithValues: item.columns.map { ($0, row.column($0)?.string) }))
        }
    }

    private func targetRows(_ connection: MySQLConnection, item: NativeDataPlanItem,
                            matching sourceRows: [NativeRow]) async throws -> [NativeRow] {
        guard !sourceRows.isEmpty else { return [] }
        let values = sourceRows.flatMap { binds($0, columns: item.keyColumns) }
        let sql = try nativeBatchTargetSQL(table: item.table, columns: item.columns,
                                           keyColumns: item.keyColumns, rowCount: sourceRows.count)
        let result = try await connection.query(sql, values).get()
        return result.map { row in
            NativeRow(values: Dictionary(uniqueKeysWithValues: item.columns.map { ($0, row.column($0)?.string) }))
        }
    }

    private func applyBatches(source: MySQLConnection, destination: MySQLConnection,
                              item: NativeDataPlanItem, transactional: Bool) async throws -> (inserted: Int, updated: Int) {
        var cursor: NativeRow?
        var inserted = 0, updated = 0
        while true {
            let sourceRows = try await batchRows(source, item: item, after: cursor)
            guard !sourceRows.isEmpty else { break }
            let destinationRows = try await targetRows(destination, item: item, matching: sourceRows)
            let diff = try nativeDiffRows(source: sourceRows, target: destinationRows, columns: item.columns,
                                          keyColumns: item.keyColumns, removeExtraRows: false)
            let batchItem = NativeDataPlanItem(table: item.table, columns: item.columns, keyColumns: item.keyColumns,
                                               sourceDDL: item.sourceDDL, targetDDL: item.targetDDL, diff: diff,
                                               fingerprint: item.fingerprint, usesBatching: true,
                                               sourceRowCount: sourceRows.count)
            if !transactional { _ = try await destination.simpleQuery("START TRANSACTION").get() }
            do {
                inserted += try await insertRows(destination, item: batchItem)
                updated += try await updateRows(destination, item: batchItem)
                if !transactional { _ = try await destination.simpleQuery("COMMIT").get() }
            } catch {
                _ = try? await destination.simpleQuery("ROLLBACK").get()
                throw error
            }
            cursor = sourceRows.last
        }
        return (inserted, updated)
    }

    private func tableColumns(_ connection: MySQLConnection, table: String) async throws -> [String] {
        let value = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(value)' ORDER BY ORDINAL_POSITION"
        return try await connection.simpleQuery(sql).get().compactMap { $0.column("COLUMN_NAME")?.string }
    }

    private func primaryKey(_ connection: MySQLConnection, table: String) async throws -> [String] {
        let value = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(value)' AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX"
        return try await connection.simpleQuery(sql).get().compactMap { $0.column("COLUMN_NAME")?.string }
    }

    private func uniqueKey(_ connection: MySQLConnection, table: String, columns: [String],
                           sourceRows: [NativeRow], targetRows: [NativeRow]) async throws -> [String] {
        let value = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT INDEX_NAME, COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(value)' AND NON_UNIQUE = 0 AND INDEX_NAME <> 'PRIMARY' ORDER BY INDEX_NAME, SEQ_IN_INDEX"
        let rows = try await connection.simpleQuery(sql).get()
        var indexes: [String: [String]] = [:]
        for row in rows {
            guard let index = row.column("INDEX_NAME")?.string, let column = row.column("COLUMN_NAME")?.string,
                  columns.contains(column) else { continue }
            indexes[index, default: []].append(column)
        }
        for key in indexes.keys.sorted() {
            guard let keyColumns = indexes[key], !keyColumns.isEmpty else { continue }
            let valid = [sourceRows, targetRows].allSatisfy { rows in
                var seen = Set<String>()
                for row in rows {
                    if keyColumns.contains(where: { row.values[$0] == nil || row.values[$0]! == nil }) { return false }
                    if !seen.insert(nativeRowKey(row, columns: keyColumns)).inserted { return false }
                }
                return true
            }
            if valid { return keyColumns }
        }
        return []
    }

    private func fingerprint(table: String, sourceDDL: String, targetDDL: String,
                             sourceRows: [NativeRow], targetRows: [NativeRow]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let source = (try? encoder.encode(sourceRows)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let target = (try? encoder.encode(targetRows)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return nativeFingerprint([table, sourceDDL, targetDDL, source, target])
    }

    private func sortRows(_ rows: [NativeRow]) -> [NativeRow] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return rows.sorted { left, right in
            let a = (try? encoder.encode(left)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let b = (try? encoder.encode(right)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return a < b
        }
    }

    private func binds(_ row: NativeRow, columns: [String]) -> [MySQLData] {
        columns.map { column in
            guard let value = row.values[column] ?? nil else { return .null }
            return MySQLData(string: value)
        }
    }

    private func execute(_ connection: MySQLConnection, sql: String, values: [MySQLData]) async throws -> UInt64 {
        let affected = NativeAffectedRows()
        _ = try await connection.query(sql, values, onMetadata: { affected.set($0.affectedRows) }).get()
        return affected.value
    }

    private func insertRows(_ connection: MySQLConnection, item: NativeDataPlanItem) async throws -> Int {
        guard !item.columns.isEmpty else { return 0 }
        let table = try quoteIdentifier(item.table), cols = try item.columns.map(quoteIdentifier)
        let sql = "INSERT INTO \(table) (\(cols.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: cols.count).joined(separator: ", ")))"
        for row in item.diff.inserts { _ = try await execute(connection, sql: sql, values: binds(row, columns: item.columns)) }
        return item.diff.inserts.count
    }

    private func updateRows(_ connection: MySQLConnection, item: NativeDataPlanItem) async throws -> Int {
        let columns = item.columns.filter { !item.keyColumns.contains($0) }
        guard !item.keyColumns.isEmpty, !columns.isEmpty else { return 0 }
        let table = try quoteIdentifier(item.table)
        let setClause = try columns.map { "\(try quoteIdentifier($0)) = ?" }.joined(separator: ", ")
        let whereClause = try item.keyColumns.map { "\(try quoteIdentifier($0)) <=> ?" }.joined(separator: " AND ")
        let sql = "UPDATE \(table) SET \(setClause) WHERE \(whereClause)"
        for pair in item.diff.updates {
            let affected = try await execute(connection, sql: sql,
                                             values: binds(pair.after, columns: columns) + binds(pair.after, columns: item.keyColumns))
            guard affected == 1 else { throw BridgeError.message(L10n.format("%@: baris tujuan berubah saat penerapan; transaksi dibatalkan.", item.table)) }
        }
        return item.diff.updates.count
    }

    private func deleteRows(_ connection: MySQLConnection, item: NativeDataPlanItem) async throws -> Int {
        let keyColumns = item.keyColumns.isEmpty ? item.columns : item.keyColumns
        guard !keyColumns.isEmpty else { return 0 }
        let table = try quoteIdentifier(item.table)
        let whereClause = try keyColumns.map { "\(try quoteIdentifier($0)) <=> ?" }.joined(separator: " AND ")
        let sql = "DELETE FROM \(table) WHERE \(whereClause)\(item.keyColumns.isEmpty ? " LIMIT 1" : "")"
        for row in item.diff.deletes {
            let affected = try await execute(connection, sql: sql, values: binds(row, columns: keyColumns))
            guard affected == 1 else { throw BridgeError.message(L10n.format("%@: baris tujuan berubah saat penerapan; transaksi dibatalkan.", item.table)) }
        }
        return item.diff.deletes.count
    }
}
