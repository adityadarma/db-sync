// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DatabaseSyncNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DatabaseSyncNative", targets: ["DatabaseSyncNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0")
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
