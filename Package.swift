// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DatabaseSyncNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DatabaseSyncNative", targets: ["DatabaseSyncNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "DatabaseSyncNative",
            dependencies: [.product(name: "MySQLNIO", package: "mysql-nio")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "DatabaseSyncNativeTests",
            dependencies: ["DatabaseSyncNative"]
        )
    ]
)
