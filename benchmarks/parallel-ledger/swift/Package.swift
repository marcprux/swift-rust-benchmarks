// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parallel-ledger",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "parallel-ledger", targets: ["ParallelLedger"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "ParallelLedger",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
