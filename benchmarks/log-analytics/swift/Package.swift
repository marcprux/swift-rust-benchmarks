// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "log-analytics",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "log-analytics", targets: ["LogAnalytics"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "LogAnalytics",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
