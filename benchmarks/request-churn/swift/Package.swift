// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "request-churn",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "request-churn", targets: ["RequestChurn"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "RequestChurn",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
