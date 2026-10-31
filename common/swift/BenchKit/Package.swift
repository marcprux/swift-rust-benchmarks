// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BenchKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BenchKit", targets: ["BenchKit"]),
    ],
    targets: [
        .target(name: "CBenchKit"),
        .target(name: "BenchKit", dependencies: ["CBenchKit"]),
    ]
)
