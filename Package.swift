// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DatabaseSyncNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DatabaseSyncNative", targets: ["DatabaseSyncNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", exact: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.80.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3")
    ],
    targets: [
        .executableTarget(
            name: "DatabaseSyncNative",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio")
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "DatabaseSyncNativeTests",
            dependencies: ["DatabaseSyncNative"]
        )
    ]
)
