// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "token-run",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TokenUsageCore", targets: ["TokenUsageCore"]),
        .executable(name: "token-usage-daemon", targets: ["token-usage-daemon"]),
        .executable(name: "token-run-menubar", targets: ["token-run-menubar"]),
    ],
    dependencies: [
        // TODO(verify): switch these path dependencies back to the official URLs when
        // the build environment can resolve GitHub:
        // https://github.com/hummingbird-project/hummingbird.git (2.x)
        // https://github.com/apple/swift-log.git
        // https://github.com/apple/swift-nio.git
        .package(path: "Vendor/hummingbird"),
        .package(path: "Vendor/swift-log"),
        .package(path: "Vendor/swift-nio"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TokenUsageCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .executableTarget(
            name: "token-usage-daemon",
            dependencies: [
                "TokenUsageCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
        .executableTarget(
            name: "token-run-menubar",
            dependencies: [
                "TokenUsageCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/BedlFrames"),
                .copy("Resources/bedl-icon.png"),
            ],
            linkerSettings: [
                // Sparkle.framework lives in TokenRun.app/Contents/Frameworks/, so
                // set @rpath to find it relative to the bundled executable.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .testTarget(
            name: "TokenUsageCoreTests",
            dependencies: [
                "TokenUsageCore",
            ],
            resources: [
                .copy("Fixtures"),
            ]),
    ]
)
