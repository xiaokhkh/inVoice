// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceOpsCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoiceOpsCore", targets: ["VoiceOpsCore"])
    ],
    targets: [
        .target(
            name: "VoiceOpsCore",
            path: "apps/macos/VoiceOpsCore"
        ),
        .testTarget(
            name: "VoiceOpsCoreTests",
            dependencies: ["VoiceOpsCore"],
            path: "tests/VoiceOpsCoreTests"
        )
    ]
)
