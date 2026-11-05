# DBSync

Native macOS application for one-way database synchronization. DBSync compares a source database with a destination, shows a change plan, then applies it only after explicit confirmation of the destination database name.

## Supported Databases

| Database | Connection | Structure sync | Data sync |
| --- | --- | --- | --- |
| MySQL | Supported | Supported | Supported |
| MariaDB | Supported | Supported | Supported |
| PostgreSQL | Not supported | Not supported | Not supported |
| CockroachDB | Not supported | Not supported | Not supported |
| SQLite | Not supported | Not supported | Not supported |

Source and destination must use the same supported driver. MySQL and MariaDB use the native MySQLNIO adapter.

## Features

- One-way MySQL-to-MySQL and MariaDB-to-MariaDB synchronization.
- Structure comparison and synchronization for base tables, columns, indexes, and supported foreign-key changes.
- Data synchronization with inserts, updates, and optional deletion of extra destination rows for snapshot-mode tables.
- Primary-key tables are synchronized in batches of 1,000 rows. DBSync reads source rows in primary-key order and loads only destination rows matching the active batch.
- Optional single transaction for data synchronization, enabled by default. For transactional MySQL/MariaDB engines such as InnoDB, a failure rolls back all data batches before commit.
- Optional per-batch transactions for very large tables. Completed batches remain applied if a later batch fails.
- Safe change review: warnings, blockers, SQL preview, and destination database-name confirmation.
- Circular foreign-key handling for structure creation, extra-table removal, and data synchronization.
- SSH tunnel support through the macOS OpenSSH client.
- App-managed connections stored in Application Support; passwords stored in macOS Keychain.
- Import compatible MySQL/MariaDB connection metadata from TablePlus and from `mysql://` or `mariadb://` URLs.
- English and Indonesian interface localization.

## Requirements

- macOS 14 or later.
- Xcode 16 or Command Line Tools with Swift 6.
- A reachable MySQL or MariaDB server for application use.

## Install

Download a `DBSync-<version>-arm64.zip` file from the GitHub release, unzip it, then move `DBSync.app` to `/Applications`.

The app is not notarized. On first launch, macOS may block it. Open the app once, then select **Open Anyway** in **System Settings > Privacy & Security**. Alternatively:

```zsh
xattr -dr com.apple.quarantine /Applications/DBSync.app
```

## Build and Run

Build the release app bundle and open it:

```zsh
zsh scripts/run-native.sh
```

Build without opening a new app window:

```zsh
zsh scripts/run-native.sh --no-open
open .build/DBSync.app
```

The app bundle is created at `.build/DBSync.app`. To set a release version while building:

```zsh
DBSYNC_VERSION=1.2.0 DBSYNC_BUILD=42 zsh scripts/run-native.sh --no-open
```

Run tests:

```zsh
swift test --disable-sandbox
```

Run the optional MySQL integration test with two empty, writable test databases. It creates and removes a temporary InnoDB table in each database, then verifies a primary-key sync over two batches:

```zsh
DBSYNC_MYSQL_TEST_HOST=127.0.0.1 \
DBSYNC_MYSQL_TEST_USER=root \
DBSYNC_MYSQL_TEST_PASSWORD=secret \
DBSYNC_MYSQL_TEST_SOURCE_DATABASE=dbsync_source_test \
DBSYNC_MYSQL_TEST_DESTINATION_DATABASE=dbsync_destination_test \
swift test --disable-sandbox --filter MySQLDataSyncIntegrationTests
```

The integration test is skipped when these environment variables are absent.

## Use

1. Open **Manage connections** and create a connection, or import compatible TablePlus metadata.
2. Select the source and destination connections and databases.
3. Choose **Structure** or **Data**, then select **Compare**.
4. Review every blocker, warning, and planned change.
5. For large primary-key tables, choose whether to use one transaction or commit each batch separately.
6. Enter the destination database name exactly, then apply the plan.

For InnoDB tables, the default data mode uses one transaction and rolls back all data changes on failure. MySQL/MariaDB DDL cannot be rolled back as one transaction. Back up the destination before applying structural changes.

## Scope and Limitations

- Only base tables are synchronized. Views, triggers, routines, events, users, permissions, and custom TLS configuration are not supported.
- Source and destination must use the same supported driver.
- PostgreSQL, CockroachDB, and SQLite may be recognized when importing connection metadata, but do not have native sync adapters.
- Data synchronization requires matching table structures and does not support generated or invisible columns.
- Tables with a primary key use key-based batches of 1,000 rows. The preview reports that batch mode will run but does not calculate or display every changed row before applying.
- Snapshot-mode tables are limited to 50,000 rows. A table without a primary key uses a usable unique index when possible; tables without either are compared as multisets of complete rows.
- Deleting extra destination rows is not available for primary-key batch mode because it requires a separate full scan of the destination.
- Full rollback requires a transactional storage engine such as InnoDB. MyISAM does not support transactions or rollback.
- Parent tables are synchronized before child tables. For a circular FK relationship, including mutually required `NOT NULL` foreign keys, DBSync temporarily disables MySQL foreign-key checks while applying the complete transaction, then restores them before commit.
- Primary-key changes, table engine/charset/collation changes, CHECK constraints, and unsafe incoming foreign-key changes require manual handling.

## License

This project is open-sourced software licensed under the [MIT license](LICENSE.md).
