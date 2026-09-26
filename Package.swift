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
        .target(
            name: "ClipboardStorage",
            path: "apps/macos/VoiceOps/Clipboard",
            exclude: ["ClipboardObserver.swift", "ClipboardHistoryViewModel.swift", "ClipboardHistoryPanel.swift",
                      "ClipboardHistoryPanelController.swift", "ClipboardHistoryView.swift", "ClipboardItemRowView.swift",
                      "HistoryWorkspaceView.swift"],
            sources: ["ClipboardItem.swift", "ClipboardStore.swift"]
        ),
        .testTarget(name: "ClipboardStorageTests", dependencies: ["ClipboardStorage"], path: "tests/ClipboardStorageTests"),
        .testTarget(
            name: "VoiceOpsCoreTests",
            dependencies: ["VoiceOpsCore"],
            path: "tests/VoiceOpsCoreTests"
        )
    ]
)
