// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "hummingbird",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Hummingbird", targets: ["Hummingbird"]),
    ],
    dependencies: [
        .package(path: "../swift-nio"),
    ],
    targets: [
        .target(
            name: "Hummingbird",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
    ]
)
