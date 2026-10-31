// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "document-tree",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "document-tree", targets: ["DocumentTree"]),
    ],
    dependencies: [
        .package(path: "../../../common/swift/BenchKit"),
    ],
    targets: [
        .executableTarget(
            name: "DocumentTree",
            dependencies: [.product(name: "BenchKit", package: "BenchKit")]
        ),
    ]
)
