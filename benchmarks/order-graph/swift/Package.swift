// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "order-graph",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "order-graph", targets: ["OrderGraph"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "OrderGraph",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
