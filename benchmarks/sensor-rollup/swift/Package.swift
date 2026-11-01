// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sensor-rollup",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sensor-rollup", targets: ["SensorRollup"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "SensorRollup",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
