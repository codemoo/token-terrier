// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-log",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Logging", targets: ["Logging"]),
    ],
    targets: [
        .target(name: "Logging"),
    ]
)
