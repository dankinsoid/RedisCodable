// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RedisCodable",
    products: [
        .library(name: "RedisCodable", targets: ["RedisCodable"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "RedisCodable",
            dependencies: ["RediStack"]
        ),
        .testTarget(
            name: "RedisCodableTests",
            dependencies: ["RedisCodable"]
        )
    ]
)
