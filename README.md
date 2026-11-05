# DBSync

Native macOS application for one-way database synchronization. DBSync compares a source database with a destination, presents a change plan, and applies only after explicit confirmation.

## Features

- MySQL to MySQL and MariaDB to MariaDB synchronization through MySQLNIO.
- Structure comparison and synchronization for base tables, columns, indexes, and supported foreign-key changes.
- Data comparison with inserts, updates, and optional deletion of extra destination rows.
- Safe change review: warnings, blockers, SQL preview, and destination database-name confirmation.
- Circular foreign-key handling for structure creation, extra-table removal, and data synchronization.
- SSH tunnel support through the macOS OpenSSH client.
- App-managed connections stored in Application Support; passwords stored in macOS Keychain.
- Import compatible MySQL/MariaDB connection metadata from TablePlus.
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

## Use

1. Open **Manage connections** and create a connection, or import compatible TablePlus metadata.
2. Select the source and destination connections and databases.
3. Choose **Structure** or **Data**, then select **Compare**.
4. Review every blocker, warning, and planned change.
5. Enter the destination database name exactly, then apply the plan.

Data changes use a transaction and roll back on failure. MySQL/MariaDB DDL cannot be rolled back as one transaction. Back up the destination before applying structural changes.

## Scope and Limitations

- Only base tables are synchronized. Views, triggers, routines, events, users, permissions, and custom TLS configuration are not supported.
- Source and destination must use the same supported driver.
- PostgreSQL and SQLite are recognized connection types but do not yet have sync adapters.
- Data synchronization requires matching table structures and does not support generated or invisible columns.
- Data comparison is limited to 50,000 rows per table.
- Tables without a primary key use a usable unique index when possible. Tables without either are compared as multisets of complete rows.
- Primary-key changes, table engine/charset/collation changes, CHECK constraints, and unsafe incoming foreign-key changes require manual handling.

## GitHub Actions

`.github/workflows/build.yml` uses the GitHub-hosted `macos-14` runner.

- Pushes to `main` and pull requests run `swift test --disable-sandbox`, build the app, and upload a 30-day ZIP artifact.
- Push a tag such as `v1.2.0` to create a GitHub Release with `DBSync-1.2.0-arm64.zip` attached.
- The app is unsigned and not notarized. Configure signing and notarization separately before distributing outside a trusted team.

## Project Layout

```text
Sources/DatabaseSyncNative/  SwiftUI app and native sync adapters
Tests/DatabaseSyncNativeTests/  Unit tests for structure and sync logic
AppAssets/                   Application icon, Info.plist, localizations
scripts/                     Local build and icon-generation scripts
.github/workflows/build.yml  GitHub Actions test, build, and release pipeline
```
