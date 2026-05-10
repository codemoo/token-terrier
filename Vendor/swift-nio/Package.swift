// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-nio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NIOCore", targets: ["NIOCore"]),
    ],
    targets: [
        .target(name: "NIOCore"),
    ]
)
