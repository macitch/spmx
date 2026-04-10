// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spmx",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "spmx", targets: ["spmx"]),
        .library(name: "SPMXCore", targets: ["SPMXCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "spmx",
            dependencies: [
                "SPMXCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "SPMXCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SPMXCoreTests",
            dependencies: ["SPMXCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
